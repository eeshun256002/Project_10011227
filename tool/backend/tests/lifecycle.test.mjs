import {test} from 'node:test';
import assert from 'node:assert/strict';
import {database,asUser,command,approvedDriverFixture} from './harness.mjs';

test('roles, booking, dispatch, waiting, payment, evidence and per-pickup custody',async t=>{
 const db=await database(); t.after(()=>db.close());
 const [client,other,driver,driver2,operator,receiver,stranger,unverified]=Array.from({length:8},()=>crypto.randomUUID());
 for(const id of [client,other,driver,driver2,operator,receiver,stranger]) await db.query('insert into auth.users values($1,now(),null)',[id]);
 await db.query('insert into auth.users(id) values($1)',[unverified]);
 for(const id of [client,other]) await db.query("insert into wm.client_profiles(user_id,full_name) values($1,'TEST Client')",[id]);
 await approvedDriverFixture(db,driver,'TEST-1');
 await approvedDriverFixture(db,driver2,'TEST-2');
 const cmd=(id,a,p={},key)=>command(db,id,a,p,key);
 const rpc=async(id,sql,args=[]) => (await asUser(db,id,sql,args)).rows[0]?.result;
 const service=async(sql,args=[])=>db.transaction(async tx=>{
   await tx.exec('set local role service_role');
   await tx.exec("select set_config('request.jwt.claim.role','service_role',true),set_config('request.jwt.claim.sub','',true)");
   return (await tx.query(sql,args)).rows[0]?.result;
 });
 const reject=(promise,code)=>assert.rejects(promise,e=>e.message.includes(code),code);
 const op=(a,p={})=>cmd(operator,'operator.'+a,{reason:'Synthetic test only',...p});
 const warehouse=(await db.query('select id from wm.warehouses')).rows[0].id;
 const payload=o=>({order_id:o.id,version:o.version});
 const read=oid=>rpc(client,'select public.wm_get_order($1) result',[oid]);
 async function quote(owner=client){
   const intent=await rpc(owner,'select public.wm_prepare_quote($1,$2,$3) result',['non_biodegradable',5.64,-0.16]);
   return service('select public.wm_finish_quote($1,10000,1200) result',[intent.intent_id]);
 }
 async function book(owner=client,extra={}){
   const q=await quote(owner);
   assert.equal(q.transport_minor,1200); // TEST tariff 100/km + 10/travel-minute.
   return cmd(owner,'booking.submit',{quote_id:q.quote_id,address:'Synthetic pickup address',...extra});
 }
 async function locate(id,seq=1){
   await cmd(id,'driver.location',{latitude:5.64,longitude:-0.16,measured_at:new Date().toISOString(),sequence:seq,accuracy_m:5});
 }
 let order,receipt,qr;
 await t.test('fail closed and deny role or quote forgery',async()=>{
   await reject(cmd(unverified,'profile.update',{display_name:'Name'}),'AUTHENTICATION_REQUIRED');
   await reject(op('settings',{bookings_enabled:true}),'FORBIDDEN');
   await reject(asUser(db,client,'insert into wm.roles values($1,\'operator\')',[client]),'permission denied');
   await reject(asUser(db,client,'update wm.settings set bookings_enabled=true'),'permission denied');
   await reject(rpc(client,'select public.wm_finish_quote($1,10,10) result',[crypto.randomUUID()]),'permission denied');
   await reject(quote(),'SERVICE_CATEGORY_UNAVAILABLE');
   await service('select public.wm_bootstrap_operator($1) result',[operator]);
 });
 await t.test('operator configuration does not invent bio availability',async()=>{
   await op('settings',{bookings_enabled:true,quote_ttl_seconds:600,offer_ttl_seconds:60,location_max_age_seconds:120,arrival_radius_m:100,waiting_rounding:'pro_rata',qr_ttl_seconds:300});
   await op('category',{category:'non_biodegradable',enabled:true});
   await reject(quote(),'WAREHOUSE_NOT_READY');
   await op('warehouse',{warehouse_id:warehouse,latitude:5.60601,longitude:-0.24717,entrance_verified:true,receiving_enabled:true,receiving_hours:'TEST only',material_restrictions:'TEST only'});
   await reject(quote(),'PRICING_NOT_CONFIGURED');
   await op('tariff',{category:'non_biodegradable',tariff_version:'TEST',per_km_minor:100,per_travel_minute_minor:10});
   await reject(quote(),'SERVICE_AREA_NOT_CONFIGURED');
   await op('area',{geojson:{type:'Polygon',coordinates:[[[-0.2,5.6],[-0.1,5.6],[-0.1,5.7],[-0.2,5.7],[-0.2,5.6]]]}});
   await reject(rpc(client,'select public.wm_prepare_quote($1,0,0) result',['non_biodegradable']),'OUTSIDE_SERVICE_AREA');
   await reject(op('category',{category:'biodegradable',enabled:true}),'RECEIVER_PENDING');
   await op('driver',{user_id:driver,plate:'TEST-1'});
   await op('driver',{user_id:driver2,plate:'TEST-2'});
   await op('receiver',{user_id:receiver,warehouse_id:warehouse});
   for(const d of [driver,driver2]) {await cmd(d,'driver.availability',{online:true});await locate(d);}
 });
 await t.test('booking idempotency and ownership',async()=>{
   const q=await quote(); const key=crypto.randomUUID(); const p={quote_id:q.quote_id,address:'Test address'};
   order=await cmd(client,'booking.submit',p,key);
   assert.deepEqual(await cmd(client,'booking.submit',p,key),order);
   await reject(cmd(client,'booking.submit',{...p,address:'Different'},key),'IDEMPOTENCY_CONFLICT');
   await reject(cmd(client,'booking.submit',p),'QUOTE_ALREADY_USED');
   await reject(rpc(other,'select public.wm_get_order($1) result',[order.id]),'NOT_FOUND');
   assert.equal((await asUser(db,other,'select * from wm.orders')).rows.length,0);
   assert.equal((await rpc(client,'select public.wm_list_orders() result')).length,1);
 });
 await t.test('full trucks excluded; offers private; acceptance locked; no refusal after acceptance',async()=>{
   await cmd(driver2,'driver.load',{load_state:'full'});
   const candidates=await rpc(operator,'select public.wm_dispatch_candidates($1) result',[order.id]);
   assert.deepEqual(candidates.candidates.map(d=>d.driver_id),[driver]);
   await reject(cmd(operator,'dispatch.offer',{order_id:order.id,driver_id:driver2}),'DRIVER_UNAVAILABLE');
   const offer=await cmd(operator,'dispatch.offer',{order_id:order.id,driver_id:driver});
   await reject(rpc(driver,'select public.wm_get_order($1) result',[order.id]),'NOT_FOUND');
   const list=await rpc(driver,'select public.wm_my_offers() result');assert.equal(list[0].address,undefined);
   await reject(cmd(driver2,'offer.accept',{offer_id:offer.offer_id}),'NOT_FOUND');
   order=await cmd(driver,'offer.accept',{offer_id:offer.offer_id});
   await reject(cmd(driver,'offer.decline',{offer_id:offer.offer_id}),'OFFER_EXPIRED');
   await reject(cmd(client,'booking.cancel',payload(order)),'OPERATOR_RESOLUTION_REQUIRED');
   await reject(cmd(driver,'driver.travel',{...payload(order),version:1}),'VERSION_CONFLICT');
   assert.equal((await rpc(client,'select public.wm_tracking($1) result',[order.id])).available,true);
 });
 await t.test('frontend reads restore scoped work, driver identity and staff access',async()=>{
   const status=await rpc(driver,'select public.wm_driver_status() result');
   assert.equal(status.online,true);assert.equal(status.location_sequence,1);
   assert.equal(status.vehicle.plate,'TEST-1');
   await reject(rpc(client,'select public.wm_driver_status() result'),'FORBIDDEN');
   const presentation=await rpc(client,'select public.wm_order_presentation($1) result',[order.id]);
   assert.equal(presentation.driver.plate,'TEST-1');
   assert.equal(presentation.driver.display_name,'TEST Driver');
   assert.deepEqual(Object.keys(presentation.driver).sort(),['display_name','plate']);
   await reject(rpc(other,'select public.wm_order_presentation($1) result',[order.id]),'NOT_FOUND');
   assert.equal((await rpc(driver,"select public.wm_active_orders('driver') result"))[0].id,order.id);
   assert.deepEqual(await rpc(other,"select public.wm_active_orders('client') result"),[]);
   const updates=await rpc(client,'select public.wm_updates() result');
   assert.ok(updates.some(e=>e.kind==='offer.accepted'));
   assert.ok(updates.every(e=>e.payload===undefined&&e.data===undefined));
   assert.deepEqual(await rpc(other,'select public.wm_updates() result'),[]);
   assert.deepEqual(await rpc(client,'select public.wm_updates($1) result',[updates.at(-1).id]),[]);
   await reject(rpc(client,"select public.wm_active_orders('client',now()) result"),'INVALID_CURSOR');
   assert.equal((await rpc(operator,'select public.wm_staff_access() result')).operator,true);
   assert.equal((await rpc(receiver,'select public.wm_staff_access() result')).warehouses[0].id,warehouse);
   assert.deepEqual(await rpc(client,'select public.wm_staff_access() result'),{operator:false,warehouses:[]});
   const eta=await rpc(client,'select public.wm_eta_context($1) result',[order.id]);
   assert.equal(eta.origin.latitude,5.64);
   await reject(rpc(other,'select public.wm_eta_context($1) result',[order.id]),'NOT_FOUND');
   await db.query("update wm.drivers set location_at=now()-interval '1 hour' where user_id=$1",[driver]);
   await reject(rpc(client,'select public.wm_eta_context($1) result',[order.id]),'STALE_LOCATION');
   await db.query('update wm.drivers set location_at=now() where user_id=$1',[driver]);
 });
 await t.test('arrival proximity, stale GPS, waiting grace and loading exclusion',async()=>{
   order=await cmd(driver,'driver.travel',payload(order));
   await db.query("update wm.drivers set location_at=now()-interval '5 minutes' where user_id=$1",[driver]);
   await reject(cmd(driver,'driver.arrive',payload(order)),'ARRIVAL_LOCATION_UNVERIFIED');
   assert.equal((await rpc(client,'select public.wm_tracking($1) result',[order.id])).available,false);
   await locate(driver,2); await reject(locate(driver,2),'STALE_LOCATION');
   order=await cmd(driver,'driver.arrive',payload(order));
   await db.query("update wm.orders set arrived_at=clock_timestamp()-interval '8 minutes' where id=$1",[order.id]);
   order=await cmd(driver,'driver.start_loading',payload(order));
   assert.equal(order.waiting_minor,270);assert.equal(order.total_minor,1570);
   await reject(cmd(driver,'driver.collect',payload(order)),'PICKUP_EVIDENCE_REQUIRED');
   const e=await cmd(driver,'evidence.reserve',{...payload(order),purpose:'pickup'});
   await reject(cmd(driver,'evidence.finalize',{evidence_id:e.evidence_id}),'UPLOAD_NOT_FOUND');
   await reject(asUser(db,other,'insert into storage.objects(bucket_id,name,owner_id) values($1,$2,$3)',[e.bucket,e.path,other]),'row-level security');
   const upload=await asUser(db,driver,'insert into storage.objects(bucket_id,name,owner_id) values($1,$2,$3) returning id',[e.bucket,e.path,driver]);
   assert.equal(upload.rows.length,1); // Storage requires SELECT for INSERT RETURNING before finalize.
   assert.equal((await asUser(db,client,'select * from storage.objects')).rows.length,0);
   await cmd(driver,'evidence.finalize',{evidence_id:e.evidence_id});
   order=await cmd(driver,'driver.collect',payload(order));assert.equal(order.waiting_minor,270);
   assert.equal((await asUser(db,other,'select * from storage.objects')).rows.length,0);
   assert.equal((await asUser(db,client,'select * from storage.objects')).rows.length,1);
   await asUser(db,driver,"delete from storage.objects where name=$1",[e.path]); // RLS filters deletion.
   assert.equal((await db.query('select * from storage.objects')).rows.length,1);
 });
 await t.test('payment gate, exact cash attestation and no fake mobile money',async()=>{
   await reject(cmd(driver,'driver.depart',payload(order)),'PAYMENT_REQUIRED');
   await reject(cmd(other,'payment.cash',{...payload(order),amount_minor:1570}),'NOT_FOUND');
   await reject(cmd(client,'payment.mobile_money',{...payload(order),network:'mtn_momo'}),'PAYMENT_PROVIDER_NOT_CONFIGURED');
   await reject(cmd(client,'payment.mobile_money',{...payload(order),network:'telecel_cash'}),'PAYMENT_PROVIDER_NOT_CONFIGURED');
   await reject(cmd(driver,'payment.cash',{...payload(order),amount_minor:1}),'PAYMENT_AMOUNT_MISMATCH');
   const key=crypto.randomUUID(); const p={...payload(order),amount_minor:1570};
   receipt=await cmd(driver,'payment.cash',p,key);assert.equal(receipt.amount_minor,1570);
   assert.deepEqual(await cmd(driver,'payment.cash',p,key),receipt);
   await reject(cmd(driver,'payment.cash',p),'PAYMENT_RECONCILIATION_REQUIRED');
   await reject(op('adjust_waiting',{...payload(order),waiting_minor:0}),'FARE_LOCKED');
   order=await cmd(driver,'driver.depart',payload(order));
   await op('cash_remittance',{payment_id:receipt.payment_id,reference:'TEST receipt'});
 });
 await t.test('QR is hashed, scoped to receiver, single use, with custody reconciliation',async()=>{
   // The same truck carries a second client's pickup. One QR must not clear it.
   let second=await book(other);
   const offer=await service('select public.wm_worker_offer($1,$2) result',[second.id,driver]);
   second=await cmd(driver,'offer.accept',{offer_id:offer.offer_id});
   second=await cmd(driver,'driver.travel',payload(second));
   second=await cmd(driver,'driver.arrive',payload(second));
   second=await cmd(driver,'driver.start_loading',payload(second));assert.equal(second.waiting_minor,0);
   const evidence=await cmd(driver,'evidence.reserve',{...payload(second),purpose:'pickup'});
   await asUser(db,driver,'insert into storage.objects(bucket_id,name,owner_id) values($1,$2,$3)',[evidence.bucket,evidence.path,driver]);
   await cmd(driver,'evidence.finalize',{evidence_id:evidence.evidence_id});
   second=await cmd(driver,'driver.collect',payload(second));
   await cmd(driver,'payment.cash',{...payload(second),amount_minor:second.total_minor});
   second=await cmd(driver,'driver.depart',payload(second));
   await cmd(driver,'driver.load',{load_state:'full'});
   await reject(op('load_reset',{driver_id:driver}),'UNRESOLVED_CUSTODY');
   const key=crypto.randomUUID();qr=await cmd(driver,'handoff.issue',payload(order),key);
   const replay=await cmd(driver,'handoff.issue',payload(order),key);assert.equal(replay.token,undefined);assert.equal(replay.refresh_required,true);
   assert.equal((await db.query('select token_hash from wm.handoffs')).rows[0].token_hash,Buffer.from(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(qr.token))).toString('hex'));
   await reject(rpc(stranger,'select public.wm_preview_handoff($1) result',[qr.token]),'INVALID_QR');
   const preview=await rpc(receiver,'select public.wm_preview_handoff($1) result',[qr.token]);assert.equal(preview.order_id,order.id);assert.equal(preview.address,undefined);
   await reject(cmd(driver,'handoff.confirm',{token:qr.token,outcome:'confirmed'}),'INVALID_QR');
   await cmd(receiver,'handoff.confirm',{token:qr.token,outcome:'partial',reason:'Test residual load'});
   const presented=await rpc(client,'select public.wm_order_presentation($1) result',[order.id]);
   assert.equal(presented.handoffs[0].status,'partial');
   assert.equal(presented.handoffs[0].reason,'Test residual load');
   assert.equal(presented.handoffs[0].token_hash,undefined);
   assert.equal(presented.payments[0].method,'cash');
   await reject(rpc(client,'select public.wm_eta_context($1) result',[order.id]),'ETA_UNAVAILABLE');
   // Same-timestamp active pickups must remain reachable via the composite cursor.
   await db.query('update wm.orders set created_at=$1 where id=$2',[order.created_at,second.id]);
   const page=await rpc(driver,"select public.wm_active_orders('driver',null,null,1) result");
   const next=await rpc(driver,"select public.wm_active_orders('driver',$1,$2,1) result",[page[0].created_at,page[0].id]);
   assert.equal(next.length,1);assert.notEqual(next[0].id,page[0].id);
   await reject(cmd(driver,'handoff.issue',payload(order)),'CUSTODY_RESOLUTION_REQUIRED');
   const incident=(await db.query("select id from wm.incidents where kind='warehouse_partial'")).rows[0];
   await op('resolve_incident',{incident_id:incident.id});
   qr=await cmd(driver,'handoff.issue',payload(order));
   await cmd(receiver,'handoff.confirm',{token:qr.token,outcome:'confirmed'});
   await reject(cmd(receiver,'handoff.confirm',{token:qr.token,outcome:'confirmed'}),'QR_EXPIRED_OR_USED');
   order=await read(order.id);assert.ok(order.warehouse_confirmed_at);
   assert.equal((await db.query('select warehouse_confirmed_at from wm.orders where id=$1',[second.id])).rows[0].warehouse_confirmed_at,null);
   await reject(op('load_reset',{driver_id:driver}),'UNRESOLVED_CUSTODY');
   const expired=await cmd(driver,'handoff.issue',payload(second));
   await db.query("update wm.handoffs set expires_at=now()-interval '1 second' where id=$1",[expired.handoff_id]);
   await reject(cmd(receiver,'handoff.confirm',{token:expired.token,outcome:'confirmed'}),'QR_EXPIRED_OR_USED');
   const secondQr=await cmd(driver,'handoff.issue',payload(second));
   await cmd(receiver,'handoff.confirm',{token:secondQr.token,outcome:'confirmed'});
   assert.deepEqual(await rpc(driver,"select public.wm_active_orders('driver') result"),[]);
   await op('load_reset',{driver_id:driver});
 });
 await t.test('failed visits revoke driver access and allow a new client booking',async()=>{
   let failed=await book();await locate(driver,3);
   const f=await cmd(operator,'dispatch.offer',{order_id:failed.id,driver_id:driver});
   failed=await cmd(driver,'offer.accept',{offer_id:f.offer_id});
   await reject(cmd(client,'booking.submit',{quote_id:(await quote()).quote_id,address:'Test replacement',replacement_of:failed.id}),'REPLACEMENT_NOT_ALLOWED');
   failed=await op('fail_visit',payload(failed));
   await reject(rpc(driver,'select public.wm_get_order($1) result',[failed.id]),'NOT_FOUND');
   const replacement=await book(client,{replacement_of:failed.id});assert.equal(replacement.replacement_of,failed.id);
   await cmd(client,'booking.cancel',payload(replacement));
 });
 await t.test('outbox leases and account suspension enforced',async()=>{
   await reject(rpc(client,'select public.wm_claim_outbox() result'),'permission denied');
   const batch=await service('select public.wm_claim_outbox(2) result');assert.equal(batch.length,2);
   await reject(service('select public.wm_finish_outbox($1,$2,true) result',[batch[0].id,crypto.randomUUID()]),'LEASE_CONFLICT');
   await service('select public.wm_finish_outbox($1,$2,true) result',[batch[0].id,batch[0].lease_token]);
   await reject(service('select public.wm_finish_outbox($1,$2,true) result',[batch[0].id,batch[0].lease_token]),'LEASE_CONFLICT');
   await op('suspend',{user_id:driver});
   await reject(cmd(driver,'driver.availability',{online:true}),'AUTHENTICATION_REQUIRED');
 });
});
