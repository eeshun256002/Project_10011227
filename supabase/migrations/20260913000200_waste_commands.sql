create function wm.service_ready(category_code text, pickup_point extensions.geometry) returns uuid
language plpgsql security definer set search_path='' as $$
declare c wm.categories; w wm.warehouses; s wm.settings; a wm.service_areas;
begin
 select * into c from wm.categories where code=category_code;
 if not found or not c.enabled or c.warehouse_id is null then perform wm.fail('SERVICE_CATEGORY_UNAVAILABLE'); end if;
 select * into w from wm.warehouses where id=c.warehouse_id;
 if not w.entrance_verified or w.routing_point is null or not w.receiving_enabled
 or nullif(w.receiving_hours,'') is null or nullif(w.material_restrictions,'') is null then
 perform wm.fail('WAREHOUSE_NOT_READY'); end if;
 if not exists(select 1 from wm.tariffs where category=category_code and active) then perform wm.fail('PRICING_NOT_CONFIGURED'); end if;
 select * into a from wm.service_areas where id='east_legon';
 if not a.verified or a.boundary is null then perform wm.fail('SERVICE_AREA_NOT_CONFIGURED'); end if;
 if not extensions.st_covers(a.boundary,pickup_point) then perform wm.fail('OUTSIDE_SERVICE_AREA'); end if;
 select * into s from wm.settings where id;
 if not s.bookings_enabled then perform wm.fail('BOOKINGS_DISABLED'); end if;
 if s.quote_ttl_seconds is null or s.offer_ttl_seconds is null or s.location_max_age_seconds is null
 or s.arrival_radius_m is null or s.waiting_rounding is null or s.qr_ttl_seconds is null then
 perform wm.fail('OPERATING_POLICY_NOT_CONFIGURED'); end if;
 return w.id;
end $$;

create function public.wm_prepare_quote(p_category text,p_latitude double precision,p_longitude double precision)
returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=wm.require_actor(); loc extensions.geometry:=wm.point(p_latitude,p_longitude);
 w uuid; intent wm.quote_intents; dest extensions.geometry; tariff uuid; ttl integer;
begin
 perform 1 from wm.profiles where id=u for update;
 if (select count(*) from wm.quote_intents where client_id=u and created_at>now()-interval '1 minute')>=10 then
 perform wm.fail('RATE_LIMITED'); end if;
 w:=wm.service_ready(p_category,loc);
 select routing_point into dest from wm.warehouses where id=w;
 select id into tariff from wm.tariffs where category=p_category and active;
 select quote_ttl_seconds into ttl from wm.settings where id;
 insert into wm.quote_intents(client_id,category,pickup,warehouse_id,destination,tariff_id,expires_at)
 values(u,p_category,loc,w,dest,tariff,now()+make_interval(secs=>ttl)) returning * into intent;
 return jsonb_build_object('intent_id',intent.id,'origin',jsonb_build_object('latitude',p_latitude,'longitude',p_longitude),
 'destination',jsonb_build_object('latitude',extensions.st_y(dest),'longitude',extensions.st_x(dest)),'expires_at',intent.expires_at);
end $$;
create function public.wm_finish_quote(p_intent_id uuid,p_distance_m integer,p_duration_s integer)
returns jsonb language plpgsql security definer set search_path='' as $$
declare i wm.quote_intents; t wm.tariffs; q wm.quotes; amount bigint;
begin
 if auth.role() is distinct from 'service_role' then perform wm.fail('FORBIDDEN'); end if;
 select * into i from wm.quote_intents where id=p_intent_id for update;
 if not found or i.expires_at<=now() then perform wm.fail('QUOTE_EXPIRED'); end if;
 if p_distance_m is null or p_duration_s is null or p_distance_m not between 1 and 1000000 or p_duration_s not between 1 and 172800 then
 perform wm.fail('INVALID_ROUTE_RESULT'); end if;
 select * into t from wm.tariffs where id=i.tariff_id;
 amount:=greatest(t.min_transport_minor,round(t.per_km_minor*p_distance_m/1000+t.per_travel_minute_minor*p_duration_s/60)::bigint);
 insert into wm.quotes(id,distance_m,duration_s,transport_minor,source)
 values(i.id,p_distance_m,p_duration_s,amount,'google_routes') on conflict(id) do nothing;
 select * into q from wm.quotes where id=i.id;
 return jsonb_build_object('quote_id',q.id,'transport_minor',q.transport_minor,'booking_minor',100,
 'estimated_total_minor',q.transport_minor+100,'currency','GHS','waiting_grace_seconds',300,'waiting_rate_minor',90,
 'distance_m',q.distance_m,'duration_s',q.duration_s,'expires_at',i.expires_at);
end $$;

create function wm.order_result(o wm.orders) returns jsonb language sql stable set search_path='' as $$
 select jsonb_build_object('id',o.id,'version',o.version,'state',o.state,'category',o.category,
 'warehouse_id',o.warehouse_id,'driver_id',o.driver_id,'address',o.address,'access_note',o.access_note,
 'latitude',extensions.st_y(o.pickup),'longitude',extensions.st_x(o.pickup),'created_at',o.created_at,
 'arrived_at',o.arrived_at,'ready_at',o.ready_at,'collected_at',o.collected_at,'departed_at',o.departed_at,
 'warehouse_confirmed_at',o.warehouse_confirmed_at,'transport_minor',o.transport_minor,
 'booking_minor',o.booking_minor,'waiting_minor',o.waiting_minor,'total_minor',o.total_minor,
 'currency','GHS','replacement_of',o.replacement_of,
 'payment_status',(select p.status from wm.payments p where p.order_id=o.id order by p.created_at desc,p.id desc limit 1))
$$;
create function wm.order_locked(p jsonb) returns wm.orders language plpgsql set search_path='' as $$
declare o wm.orders;
begin
 select * into o from wm.orders where id=(p->>'order_id')::uuid for update;
 if not found or not wm.can_read_order(o.id) then perform wm.fail('NOT_FOUND'); end if;
 if p->>'version' is null or o.version<>(p->>'version')::integer then perform wm.fail('VERSION_CONFLICT'); end if;
 return o;
end $$;
create function wm.cmd_order(action text,p jsonb) returns jsonb language plpgsql set search_path='' as $$
declare u uuid:=auth.uid(); o wm.orders; qi wm.quote_intents; q wm.quotes; w uuid; s wm.settings;
 e wm.evidence; prior wm.orders; wait_s numeric; wait_fee bigint;
begin
 if action='booking.submit' then
   select * into qi from wm.quote_intents where id=(p->>'quote_id')::uuid for update;
   if not found or qi.client_id<>u then perform wm.fail('NOT_FOUND'); end if;
   if qi.expires_at<=now() then perform wm.fail('QUOTE_EXPIRED'); end if;
   select * into q from wm.quotes where id=qi.id;
   if not found then perform wm.fail('QUOTE_NOT_READY'); end if;
   w:=wm.service_ready(qi.category,qi.pickup);
   if w<>qi.warehouse_id then perform wm.fail('QUOTE_DESTINATION_CHANGED'); end if;
   if exists(select 1 from wm.warehouses where id=w and not extensions.st_equals(routing_point,qi.destination)) then
   perform wm.fail('QUOTE_DESTINATION_CHANGED'); end if;
   if exists(select 1 from wm.orders where quote_id=q.id) then perform wm.fail('QUOTE_ALREADY_USED'); end if;
   if nullif(btrim(p->>'address'),'') is null then perform wm.fail('ADDRESS_REQUIRED'); end if;
   if p->>'replacement_of' is not null then
     select * into prior from wm.orders where id=(p->>'replacement_of')::uuid for update;
     if not found or prior.client_id<>u or prior.state not in ('failed','cancelled') or prior.collected_at is not null then
     perform wm.fail('REPLACEMENT_NOT_ALLOWED'); end if;
     if exists(select 1 from wm.payments where order_id=prior.id and status in ('pending','paid')) then
     perform wm.fail('PAYMENT_RECONCILIATION_REQUIRED'); end if;
   end if;
   select * into s from wm.settings where id;
   insert into wm.orders(client_id,quote_id,category,warehouse_id,pickup,address,access_note,transport_minor,waiting_rounding,replacement_of)
   values(u,q.id,qi.category,w,qi.pickup,btrim(p->>'address'),coalesce(p->>'access_note',''),q.transport_minor,s.waiting_rounding,prior.id)
   returning * into o;
   perform wm.emit(o.id,'dispatch.requested');
 elsif action='booking.cancel' then
   o:=wm.order_locked(p);
   if o.client_id<>u or o.state<>'searching' then perform wm.fail('OPERATOR_RESOLUTION_REQUIRED'); end if;
   update wm.offers set status='revoked' where order_id=o.id and status='offered';
   update wm.orders set state='cancelled',version=version+1 where id=o.id returning * into o;
   perform wm.emit(o.id,'booking.cancelled');
 elsif action in ('driver.travel','driver.arrive','driver.start_loading','driver.collect','driver.depart') then
   o:=wm.order_locked(p);
   if o.driver_id is distinct from u or not wm.is_driver() then perform wm.fail('FORBIDDEN'); end if;
   if action='driver.travel' then
     if o.state<>'accepted' then perform wm.fail('INVALID_TRANSITION'); end if;
     update wm.orders set state='en_route',version=version+1 where id=o.id returning * into o;
   elsif action='driver.arrive' then
     if o.state<>'en_route' then perform wm.fail('INVALID_TRANSITION'); end if;
     select * into s from wm.settings where id;
     if not exists(select 1 from wm.drivers d where d.user_id=u and d.location_at>now()-make_interval(secs=>s.location_max_age_seconds)
       and d.accuracy_m<=s.arrival_radius_m and extensions.st_dwithin(d.location::extensions.geography,o.pickup::extensions.geography,s.arrival_radius_m)) then
       perform wm.fail('ARRIVAL_LOCATION_UNVERIFIED'); end if;
     update wm.orders set state='arrived',arrived_at=clock_timestamp(),version=version+1 where id=o.id returning * into o;
   elsif action='driver.start_loading' then
     if o.state<>'arrived' then perform wm.fail('INVALID_TRANSITION'); end if;
     wait_s:=greatest(0,extract(epoch from (clock_timestamp()-o.arrived_at))-300);
     if o.waiting_rounding='ceil_minute' then wait_fee:=ceil(wait_s/60)*90;
     else wait_fee:=round(wait_s*90/60); end if;
     update wm.orders set state='loading',ready_at=clock_timestamp(),waiting_minor=wait_fee,
       total_minor=booking_minor+transport_minor+wait_fee,version=version+1 where id=o.id returning * into o;
   elsif action='driver.collect' then
     if o.state<>'loading' then perform wm.fail('INVALID_TRANSITION'); end if;
     if not exists(select 1 from wm.evidence where order_id=o.id and purpose='pickup' and finalized and uploader_id=u) then
     perform wm.fail('PICKUP_EVIDENCE_REQUIRED'); end if;
     update wm.orders set state='collected',collected_at=clock_timestamp(),version=version+1 where id=o.id returning * into o;
   else
     if o.state<>'collected' or o.departed_at is not null then perform wm.fail('INVALID_TRANSITION'); end if;
     if not exists(select 1 from wm.payments where order_id=o.id and status='paid' and amount_minor=o.total_minor)
       and o.departure_override_reason is null then perform wm.fail('PAYMENT_REQUIRED'); end if;
     update wm.orders set departed_at=clock_timestamp(),version=version+1 where id=o.id returning * into o;
   end if;
   perform wm.emit(o.id,action);
 elsif action='evidence.reserve' then
   o:=wm.order_locked(p);
   if p->>'purpose' not in ('pickup','incident') or p->>'purpose' is null then perform wm.fail('INVALID_EVIDENCE_PURPOSE'); end if;
   insert into wm.evidence(order_id,uploader_id,purpose,object_path)
   values(o.id,u,p->>'purpose',u::text||'/'||o.id::text||'/'||gen_random_uuid()::text) returning * into e;
   return jsonb_build_object('evidence_id',e.id,'bucket','wm-evidence','path',e.object_path);
 elsif action='evidence.finalize' then
   select * into e from wm.evidence where id=(p->>'evidence_id')::uuid for update;
   if not found or e.uploader_id<>u or not wm.can_read_order(e.order_id) then perform wm.fail('NOT_FOUND'); end if;
   if not exists(select 1 from storage.objects where bucket_id='wm-evidence' and name=e.object_path and owner_id=u::text) then
   perform wm.fail('UPLOAD_NOT_FOUND'); end if;
   update wm.evidence set finalized=true where id=e.id;
   return jsonb_build_object('evidence_id',e.id,'finalized',true);
 else perform wm.fail('UNKNOWN_COMMAND');
 end if;
 return wm.order_result(o);
end $$;

create function wm.cmd_driver(action text,p jsonb) returns jsonb language plpgsql set search_path='' as $$
declare u uuid:=auth.uid(); d wm.drivers; o wm.orders; f wm.offers; s wm.settings; pt extensions.geometry; stamp timestamptz;
begin
 if action in ('dispatch.offer','dispatch.expire') then
   if not wm.is_operator() and auth.role() is distinct from 'service_role' then perform wm.fail('FORBIDDEN'); end if;
   if action='dispatch.expire' then
     with expired as (update wm.offers set status='expired' where status='offered' and expires_at<=now() returning order_id)
     insert into wm.outbox(order_id,kind) select order_id,'dispatch.requested' from expired;
     return jsonb_build_object('expired',true);
   end if;
   select * into o from wm.orders where id=(p->>'order_id')::uuid for update;
   if not found or o.state<>'searching' then perform wm.fail('ORDER_NOT_SEARCHING'); end if;
   select * into d from wm.drivers where user_id=(p->>'driver_id')::uuid for update;
   select * into s from wm.settings where id;
   if s.offer_ttl_seconds is null then perform wm.fail('OPERATING_POLICY_NOT_CONFIGURED'); end if;
   if d.user_id is null or not d.approved or not d.online or d.load_state not in ('available','nearly_full')
   or d.location is null or d.location_at is null or d.accuracy_m is null
   or d.location_at<=now()-make_interval(secs=>s.location_max_age_seconds) or d.accuracy_m>s.arrival_radius_m
   or not exists(select 1 from wm.profiles where id=d.user_id and active)
   or not exists(select 1 from wm.roles where user_id=d.user_id and role='driver')
   or not exists(select 1 from wm.vehicles where id=d.vehicle_id and active and o.category=any(categories))
   or exists(select 1 from wm.orders where driver_id=d.user_id and departed_at is null and state in ('accepted','en_route','arrived','loading','collected')) then
   perform wm.fail('DRIVER_UNAVAILABLE'); end if;
   perform wm.service_ready(o.category,o.pickup);
   if exists(select 1 from wm.offers where order_id=o.id and driver_id=d.user_id and status in ('declined','expired')) then
     perform wm.fail('OFFER_ALREADY_ATTEMPTED'); end if;
   update wm.offers set status='expired' where status='offered' and expires_at<=now() and (driver_id=d.user_id or order_id=o.id);
   insert into wm.offers(order_id,driver_id,expires_at) values(o.id,d.user_id,now()+make_interval(secs=>s.offer_ttl_seconds)) returning * into f;
   perform wm.emit(o.id,'offer.created',jsonb_build_object('offer_id',f.id,'driver_id',d.user_id));
   return jsonb_build_object('offer_id',f.id,'expires_at',f.expires_at);
 end if;
 if not wm.is_driver() then perform wm.fail('FORBIDDEN'); end if;
 if action in ('offer.accept','offer.decline') then
   -- Always lock order before driver/offer, matching dispatch.offer lock order.
   select order_id into f.order_id from wm.offers where id=(p->>'offer_id')::uuid and driver_id=u;
   if not found then perform wm.fail('NOT_FOUND'); end if;
   select * into o from wm.orders where id=f.order_id for update;
   select * into d from wm.drivers where user_id=u for update;
   select * into f from wm.offers where id=(p->>'offer_id')::uuid for update;
   if f.status<>'offered' or f.expires_at<=now() or o.state<>'searching' then perform wm.fail('OFFER_EXPIRED'); end if;
   if action='offer.decline' then
     update wm.offers set status='declined' where id=f.id;
     perform wm.emit(o.id,'dispatch.requested');
     return jsonb_build_object('declined',true);
   end if;
   if not d.online or d.load_state not in ('available','nearly_full')
   or d.location is null or d.location_at is null or d.accuracy_m is null
   or d.location_at<=now()-make_interval(secs=>(select location_max_age_seconds from wm.settings where id))
   or d.accuracy_m>(select arrival_radius_m from wm.settings where id)
   or not exists(select 1 from wm.vehicles where id=d.vehicle_id and active and o.category=any(categories))
   or exists(select 1 from wm.orders where driver_id=u and departed_at is null and state in ('accepted','en_route','arrived','loading','collected')) then
   perform wm.fail('DRIVER_UNAVAILABLE'); end if;
   perform wm.service_ready(o.category,o.pickup);
   update wm.offers set status='accepted' where id=f.id;
   update wm.orders set driver_id=u,vehicle_id=d.vehicle_id,state='accepted',version=version+1 where id=o.id returning * into o;
   perform wm.emit(o.id,'offer.accepted');
   return wm.order_result(o);
 end if;
 select * into d from wm.drivers where user_id=u for update;
 if action='driver.availability' then
   update wm.drivers set online=(p->>'online')::boolean where user_id=u;
 elsif action='driver.location' then
   pt:=wm.point((p->>'latitude')::double precision,(p->>'longitude')::double precision);
   stamp:=(p->>'measured_at')::timestamptz;
   if not d.online or stamp is null or stamp>now()+interval '30 seconds' or stamp<now()-interval '10 minutes'
   or p->>'sequence' is null or (p->>'sequence')::bigint<=d.location_sequence
   or (d.location_at is not null and stamp<d.location_at) then perform wm.fail('STALE_LOCATION'); end if;
   if p->>'accuracy_m' is null then perform wm.fail('INVALID_LOCATION'); end if;
   update wm.drivers set location=pt,location_at=stamp,location_received_at=clock_timestamp(),
   accuracy_m=(p->>'accuracy_m')::numeric,location_sequence=(p->>'sequence')::bigint where user_id=u;
 elsif action='driver.load' then
   if p->>'load_state' not in ('full','nearly_full','unknown') or p->>'load_state' is null then perform wm.fail('LOAD_RESET_REQUIRES_RECONCILIATION'); end if;
   update wm.drivers set load_state=p->>'load_state' where user_id=u;
   if p->>'load_state'='full' then perform wm.emit(null,'warehouse.route_required',jsonb_build_object('driver_id',u)); end if;
 else perform wm.fail('UNKNOWN_COMMAND'); end if;
 return jsonb_build_object('updated',true);
end $$;

create function wm.cmd_payment(action text,p jsonb) returns jsonb language plpgsql set search_path='' as $$
declare o wm.orders; pay wm.payments;
begin
 o:=wm.order_locked(p);
 if action='payment.mobile_money' then
   if o.client_id<>auth.uid() then perform wm.fail('FORBIDDEN'); end if;
   if p->>'network' not in ('mtn_momo','telecel_cash') or p->>'network' is null then perform wm.fail('UNSUPPORTED_NETWORK'); end if;
   -- Networks selected, merchant/API integration NOT selected. Fail closed.
   perform wm.fail('PAYMENT_PROVIDER_NOT_CONFIGURED');
 elsif action='payment.cash' then
   if o.driver_id is distinct from auth.uid() or not wm.is_driver() then perform wm.fail('FORBIDDEN'); end if;
   if o.state<>'collected' or o.departed_at is not null then perform wm.fail('INVALID_TRANSITION'); end if;
   if (p->>'amount_minor')::bigint is distinct from o.total_minor then perform wm.fail('PAYMENT_AMOUNT_MISMATCH'); end if;
   if exists(select 1 from wm.payments where order_id=o.id and status in ('pending','paid')) then perform wm.fail('PAYMENT_RECONCILIATION_REQUIRED'); end if;
   insert into wm.payments(order_id,method,amount_minor,status,attested_by)
   values(o.id,'cash',o.total_minor,'paid',auth.uid()) returning * into pay;
   perform wm.emit(o.id,'payment.cash_attested',jsonb_build_object('payment_id',pay.id));
   return jsonb_build_object('payment_id',pay.id,'status','paid','method','cash','amount_minor',pay.amount_minor,'currency','GHS','attestation','driver');
 else perform wm.fail('UNKNOWN_COMMAND'); end if;
 return '{}';
end $$;

create function wm.cmd_handoff(action text,p jsonb) returns jsonb language plpgsql set search_path='' as $$
declare o wm.orders; h wm.handoffs; token text; s wm.settings; reason text;
begin
 if action='handoff.issue' then
   o:=wm.order_locked(p);
   if o.driver_id is distinct from auth.uid() or not wm.is_driver() then perform wm.fail('FORBIDDEN'); end if;
   if o.state<>'collected' or o.departed_at is null or o.warehouse_confirmed_at is not null then perform wm.fail('HANDOFF_NOT_READY'); end if;
   if exists(select 1 from wm.incidents where order_id=o.id and kind in ('warehouse_partial','warehouse_rejected') and status='open') then
     perform wm.fail('CUSTODY_RESOLUTION_REQUIRED'); end if;
   select * into s from wm.settings where id;
   if s.qr_ttl_seconds is null then perform wm.fail('OPERATING_POLICY_NOT_CONFIGURED'); end if;
   update wm.handoffs set status='revoked' where order_id=o.id and status='presented';
   token:=replace(gen_random_uuid()::text||gen_random_uuid()::text,'-','');
   insert into wm.handoffs(order_id,driver_id,warehouse_id,token_hash,expires_at)
   values(o.id,auth.uid(),o.warehouse_id,encode(sha256(convert_to(token,'UTF8')),'hex'),now()+make_interval(secs=>s.qr_ttl_seconds)) returning * into h;
   return jsonb_build_object('handoff_id',h.id,'token',token,'expires_at',h.expires_at,'order_id',o.id);
 elsif action='handoff.confirm' then
   if nullif(p->>'token','') is null then perform wm.fail('INVALID_QR'); end if;
   select * into h from wm.handoffs where token_hash=encode(sha256(convert_to(p->>'token','UTF8')),'hex');
   if not found or not wm.is_receiver(h.warehouse_id) or h.driver_id=auth.uid() then perform wm.fail('INVALID_QR'); end if;
   select * into o from wm.orders where id=h.order_id for update;
   select * into h from wm.handoffs where id=h.id for update;
   if h.status<>'presented' or h.expires_at<=now() then perform wm.fail('QR_EXPIRED_OR_USED'); end if;
   if o.state<>'collected' or o.warehouse_confirmed_at is not null then perform wm.fail('HANDOFF_NOT_READY'); end if;
   if p->>'outcome' not in ('confirmed','partial','rejected') or p->>'outcome' is null then perform wm.fail('INVALID_OUTCOME'); end if;
   if p->>'outcome'<>'confirmed' and length(coalesce(p->>'reason',''))<3 then perform wm.fail('REASON_REQUIRED'); end if;
   update wm.handoffs set status=p->>'outcome',reason=left(p->>'reason',2000),receiver_id=auth.uid(),confirmed_at=clock_timestamp() where id=h.id;
   if p->>'outcome'='confirmed' then
     update wm.orders set warehouse_confirmed_at=clock_timestamp(),version=version+1 where id=o.id;
   else
     insert into wm.incidents(order_id,reporter_id,kind,details) values(o.id,auth.uid(),'warehouse_'||(p->>'outcome'),p->>'reason');
   end if;
   perform wm.emit(o.id,'handoff.'||(p->>'outcome'));
   return jsonb_build_object('order_id',o.id,'outcome',p->>'outcome','handoff_id',h.id);
 else perform wm.fail('UNKNOWN_COMMAND'); end if;
end $$;
