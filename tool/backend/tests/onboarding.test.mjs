import {test} from 'node:test';
import assert from 'node:assert/strict';
import {database,asUser,command} from './harness.mjs';

test('separate app enrollment and verified driver documents',async t=>{
 const db=await database();t.after(()=>db.close());
 const [driver,other,client,operator,unverified]=Array.from({length:5},()=>crypto.randomUUID());
 for(const id of [driver,other,client,operator])await db.query('insert into auth.users values($1,now(),null)',[id]);
 await db.query('insert into auth.users(id) values($1)',[unverified]);
 await db.query("insert into wm.roles values($1,'operator')",[operator]);
 const rpc=async(id,sql,p=[]) => (await asUser(db,id,sql,p)).rows[0]?.result;
 const onboard=(id,action,p={},key=crypto.randomUUID())=>rpc(id,'select public.wm_onboarding_command($1,$2::jsonb,$3) result',[action,JSON.stringify(p),key]);
 const reject=(promise,code)=>assert.rejects(promise,e=>e.message.includes(code),code);
 const read=()=>rpc(driver,'select public.wm_my_driver_application() result');
 const access=id=>rpc(id,'select public.wm_account_access() result');
 let a;const docs={};
 async function action(id,name,p={}){
  const result=await onboard(id,name,{application_id:a.id,version:a.version,...p});a=await read();return result;
 }
 async function upload(kind,extra={}){
  const doc=await action(driver,'document.reserve',{kind,content_type:'image/jpeg',
    ...(kind!=='profile_photo'?{document_number:'TEST-'+kind,license_class:'TEST',expires_on:'2090-01-01'}:{}),...extra});
  await asUser(db,driver,'insert into storage.objects(bucket_id,name,owner_id,metadata) values($1,$2,$3,$4::jsonb)',
    [doc.bucket,doc.path,driver,JSON.stringify({mimetype:'image/jpeg',size:2048})]);
  await action(driver,'document.finalize',{document_id:doc.document_id});docs[kind]=doc;
 }
 await t.test('signup enrollment and credentials stay separate from staff privileges',async()=>{
  await reject(onboard(unverified,'client.register',{full_name:'Test Client'}),'AUTHENTICATION_REQUIRED');
  const key=crypto.randomUUID();const payload={full_name:'Test Client'};
  assert.deepEqual(await onboard(client,'client.register',payload,key),await onboard(client,'client.register',payload,key));
  assert.equal((await access(client)).client_registered,true);assert.equal((await access(client)).driver_can_take_jobs,false);
  await reject(rpc(driver,"select public.wm_prepare_quote('non_biodegradable',5.64,-0.16) result"),'CLIENT_REGISTRATION_REQUIRED');
  await reject(command(db,operator,'operator.driver',{reason:'TEST','user_id':driver,plate:'TEST-DRIVER'}),'DRIVER_DOCUMENT_APPROVAL_REQUIRED');
  a=await onboard(driver,'application.save',{full_name:'Test Driver',vehicle_plate:'test-driver',date_of_birth:'1990-01-01'});
  assert.equal(a.vehicle_plate,'TEST-DRIVER');assert.equal(a.status,'draft');assert.equal((await access(driver)).client_registered,false);
  await reject(asUser(db,driver,"update wm.driver_applications set status='approved'"),'permission denied');
  await reject(rpc(other,'select public.wm_driver_application($1) result',[a.id]),'NOT_FOUND');
  await reject(action(driver,'application.submit'),'REQUIRED_DOCUMENTS_MISSING_OR_EXPIRED');
  await reject(action(driver,'operator.review_application',{decision:'approved',reason:'TEST'}),'FORBIDDEN');
 });
 await t.test('document constraints and private upload',async()=>{
  await reject(action(driver,'document.reserve',{kind:'profile_photo',content_type:'application/pdf'}),'INVALID_DOCUMENT_TYPE');
  await reject(action(driver,'document.reserve',{kind:'driving_license',content_type:'image/jpeg',expires_on:'2000-01-01'}),'DOCUMENT_NOT_CURRENT');
  await reject(action(driver,'document.reserve',{kind:'driving_license',content_type:'image/jpeg',expires_on:'2090-01-01'}),'LICENSE_DETAILS_REQUIRED');
  const reservation=await action(driver,'document.reserve',{kind:'profile_photo',content_type:'image/jpeg'});
  await reject(action(driver,'document.finalize',{document_id:reservation.document_id}),'VALID_UPLOAD_REQUIRED');
  for(const id of [client,other,operator]) await reject(asUser(db,id,'insert into storage.objects(bucket_id,name,owner_id) values($1,$2,$3)',[reservation.bucket,reservation.path,id]),'row-level security');
  for(const kind of ['driving_license','profile_photo','vehicle_insurance','roadworthiness'])await upload(kind);
  assert.equal(a.documents.length,4); // Ghana Card intentionally omitted.
  assert.equal((await asUser(db,client,"select * from wm.driver_documents")).rows.length,0);
  assert.equal((await asUser(db,client,"select * from storage.objects where bucket_id='wm-driver-documents'")).rows.length,0);
  assert.equal((await asUser(db,operator,"select * from storage.objects where bucket_id='wm-driver-documents'")).rows.length,4);
  await asUser(db,driver,"delete from storage.objects where bucket_id='wm-driver-documents'");
  assert.equal((await db.query("select * from storage.objects where bucket_id='wm-driver-documents'")).rows.length,4);
 });
 await t.test('firm approval requires each required document; signing in does not authorize jobs',async()=>{
  await action(driver,'application.submit');assert.equal(a.status,'submitted');
  await reject(action(driver,'document.reserve',{kind:'ghana_card',content_type:'image/jpeg'}),'APPLICATION_LOCKED');
  await reject(action(operator,'operator.review_application',{decision:'approved',reason:'TEST verified'}),'DOCUMENT_REVIEW_REQUIRED');
  await db.query("insert into wm.roles values($1,'operator')",[driver]);
  await reject(action(driver,'operator.review_application',{decision:'approved',reason:'TEST verified'}),'SELF_REVIEW_FORBIDDEN');
  await db.query("delete from wm.roles where user_id=$1 and role='operator'",[driver]);
  for(const doc of Object.values(docs))await action(operator,'operator.review_document',{document_id:doc.document_id,decision:'approved',reason:'TEST manual verification'});
  await action(operator,'operator.review_application',{decision:'approved',reason:'TEST all verified'});
  assert.equal(a.status,'approved');assert.equal(a.review_history.length,5);
  assert.equal((await access(driver)).driver_can_take_jobs,false);
  await reject(command(db,operator,'operator.driver',{reason:'TEST',user_id:driver,plate:'OTHER-VEHICLE'}),'DRIVER_DOCUMENT_APPROVAL_REQUIRED');
  await command(db,operator,'operator.driver',{reason:'TEST',user_id:driver,plate:'TEST-DRIVER'});
  assert.equal((await access(driver)).driver_can_take_jobs,true);
  await command(db,driver,'driver.availability',{online:true});
 });
 await t.test('expiry, revocation and renewal block new jobs and preserve document history',async()=>{
  await db.query("update wm.driver_documents set expires_on=current_date-1 where id=$1",[docs.vehicle_insurance.document_id]);
  assert.equal((await access(driver)).driver_can_take_jobs,false);
  await reject(command(db,driver,'driver.availability',{online:true}),'DRIVER_DOCUMENT_APPROVAL_REQUIRED');
  await reject(command(db,operator,'dispatch.offer',{order_id:crypto.randomUUID(),driver_id:driver}),'DRIVER_DOCUMENT_APPROVAL_REQUIRED');
  await action(operator,'operator.review_document',{document_id:docs.vehicle_insurance.document_id,decision:'revoked',reason:'TEST expired insurance'});
  assert.equal(a.status,'changes_requested');
  await upload('vehicle_insurance');
  assert.equal((await db.query("select count(*)::int n from wm.driver_documents where application_id=$1 and kind='vehicle_insurance'",[a.id])).rows[0].n,2);
  await action(driver,'application.submit');
  await action(operator,'operator.review_document',{document_id:docs.vehicle_insurance.document_id,decision:'approved',reason:'TEST renewed insurance'});
  await action(operator,'operator.review_application',{decision:'approved',reason:'TEST renewal accepted'});
  assert.equal((await access(driver)).driver_can_take_jobs,true);
 });
});
