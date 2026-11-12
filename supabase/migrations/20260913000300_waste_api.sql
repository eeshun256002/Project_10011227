create function wm.cmd_operator(action text,p jsonb) returns jsonb language plpgsql set search_path='' as $$
declare o wm.orders; actor uuid:=auth.uid(); target_id uuid; geom extensions.geometry; pay wm.payments;
begin
 if not wm.is_operator() then perform wm.fail('FORBIDDEN'); end if;
 if length(coalesce(p->>'reason',''))<3 then perform wm.fail('REASON_REQUIRED'); end if;
 if action='operator.settings' then
   update wm.settings set
    bookings_enabled=coalesce((p->>'bookings_enabled')::boolean,bookings_enabled),
    quote_ttl_seconds=coalesce((p->>'quote_ttl_seconds')::integer,quote_ttl_seconds),
    offer_ttl_seconds=coalesce((p->>'offer_ttl_seconds')::integer,offer_ttl_seconds),
    location_max_age_seconds=coalesce((p->>'location_max_age_seconds')::integer,location_max_age_seconds),
    arrival_radius_m=coalesce((p->>'arrival_radius_m')::integer,arrival_radius_m),
    waiting_rounding=coalesce(p->>'waiting_rounding',waiting_rounding),
    qr_ttl_seconds=coalesce((p->>'qr_ttl_seconds')::integer,qr_ttl_seconds) where id;
 elsif action='operator.area' then
   geom:=extensions.st_multi(extensions.st_setsrid(extensions.st_geomfromgeojson(p->>'geojson'),4326));
   if geom is null or not extensions.st_isvalid(geom) or extensions.st_isempty(geom)
   or extensions.st_geometrytype(geom)<>'ST_MultiPolygon' then perform wm.fail('INVALID_SERVICE_BOUNDARY'); end if;
   update wm.service_areas set boundary=geom,verified=true where id='east_legon';
 elsif action='operator.warehouse' then
   target_id:=(p->>'warehouse_id')::uuid;
   if not exists(select 1 from wm.warehouses where warehouses.id=target_id) then perform wm.fail('NOT_FOUND'); end if;
   if p ? 'latitude' then geom:=wm.point((p->>'latitude')::double precision,(p->>'longitude')::double precision); end if;
   update wm.warehouses set routing_point=coalesce(geom,routing_point),
     entrance_verified=coalesce((p->>'entrance_verified')::boolean,entrance_verified),
     receiving_enabled=coalesce((p->>'receiving_enabled')::boolean,receiving_enabled),
     receiving_hours=coalesce(p->>'receiving_hours',receiving_hours),material_restrictions=coalesce(p->>'material_restrictions',material_restrictions)
     where warehouses.id=target_id;
 elsif action='operator.category' then
   -- Initial release does not offer a toggle to bypass the missing biodegradable partner.
   if p->>'category' is distinct from 'non_biodegradable' then perform wm.fail('RECEIVER_PENDING'); end if;
   update wm.categories set enabled=(p->>'enabled')::boolean where code=p->>'category';
 elsif action='operator.tariff' then
   if p->>'category' is distinct from 'non_biodegradable' then perform wm.fail('RECEIVER_PENDING'); end if;
   update wm.tariffs set active=false where category=p->>'category' and active;
   insert into wm.tariffs(category,version,per_km_minor,per_travel_minute_minor,min_transport_minor,active)
   values(p->>'category',p->>'tariff_version',(p->>'per_km_minor')::numeric,(p->>'per_travel_minute_minor')::numeric,
     coalesce((p->>'min_transport_minor')::bigint,0),true) returning tariffs.id into target_id;
 elsif action='operator.driver' then
   if not exists(select 1 from wm.profiles where profiles.id=(p->>'user_id')::uuid) then perform wm.fail('ACCOUNT_NOT_FOUND'); end if;
   insert into wm.vehicles(plate,categories) values(p->>'plate',array['non_biodegradable'])
   on conflict(plate) do update set active=true returning vehicles.id into target_id;
   insert into wm.roles(user_id,role) values((p->>'user_id')::uuid,'driver') on conflict do nothing;
   if exists(select 1 from wm.orders where driver_id=(p->>'user_id')::uuid and state='collected' and warehouse_confirmed_at is null)
     or exists(select 1 from wm.orders where driver_id=(p->>'user_id')::uuid and state in ('accepted','en_route','arrived','loading')) then
     perform wm.fail('DRIVER_HAS_OBLIGATIONS'); end if;
   insert into wm.drivers(user_id,vehicle_id,approved,load_state)
   values((p->>'user_id')::uuid,target_id,true,'available') on conflict(user_id) do update set vehicle_id=excluded.vehicle_id,approved=true;
 elsif action='operator.receiver' then
   insert into wm.roles(user_id,role) values((p->>'user_id')::uuid,'receiver') on conflict do nothing;
   insert into wm.receiver_memberships(user_id,warehouse_id) values((p->>'user_id')::uuid,(p->>'warehouse_id')::uuid) on conflict do nothing;
 elsif action='operator.suspend' then
   if (p->>'user_id')::uuid=actor then perform wm.fail('CANNOT_SUSPEND_SELF'); end if;
   update wm.profiles set active=false where profiles.id=(p->>'user_id')::uuid;
   update wm.drivers set online=false,approved=false where user_id=(p->>'user_id')::uuid;
   insert into wm.incidents(reporter_id,kind,details) values(actor,'staff_suspended',p->>'reason');
 elsif action='operator.load_reset' then
   perform 1 from wm.drivers where user_id=(p->>'driver_id')::uuid for update;
   if not found then perform wm.fail('NOT_FOUND'); end if;
   if exists(select 1 from wm.orders where driver_id=(p->>'driver_id')::uuid and
       ((state='collected' and warehouse_confirmed_at is null) or state in ('accepted','en_route','arrived','loading'))) then
       perform wm.fail('UNRESOLVED_CUSTODY'); end if;
   update wm.drivers set load_state='available' where user_id=(p->>'driver_id')::uuid;
 elsif action='operator.retry_dispatch' then
   o:=wm.order_locked(p);
   if o.state<>'searching' then perform wm.fail('ORDER_NOT_SEARCHING'); end if;
   if exists(select 1 from wm.offers where order_id=o.id and status='offered' and expires_at>now()) then perform wm.fail('OFFER_ALREADY_OPEN'); end if;
   -- A retry does not re-offer drivers who already declined this attempt.
   update wm.outbox set status='pending',attempts=0,available_at=now(),lease_until=null,lease_token=null,last_error=null
     where order_id=o.id and kind='dispatch.requested' and status='dead';
   if not found then perform wm.emit(o.id,'dispatch.requested'); end if;
 elsif action in ('operator.fail_visit','operator.departure_override','operator.adjust_waiting') then
   o:=wm.order_locked(p);
   if action='operator.fail_visit' then
     if o.state not in ('searching','accepted','en_route','arrived') then perform wm.fail('CUSTODY_REQUIRES_RESOLUTION'); end if;
     update wm.offers set status='revoked' where order_id=o.id and status='offered';
     update wm.orders set state='failed',version=version+1 where orders.id=o.id returning * into o;
   elsif action='operator.departure_override' then
     if o.state<>'collected' or o.departed_at is not null then perform wm.fail('INVALID_TRANSITION'); end if;
     update wm.orders set departure_override_reason=p->>'reason',version=version+1 where orders.id=o.id returning * into o;
     insert into wm.incidents(order_id,reporter_id,kind,details) values(o.id,actor,'departure_exception',p->>'reason');
   else
     if o.state not in ('loading','collected') or o.departed_at is not null
     or exists(select 1 from wm.payments where order_id=o.id and status in ('pending','paid')) then
       perform wm.fail('FARE_LOCKED'); end if;
     if p->>'waiting_minor' is null or (p->>'waiting_minor')::bigint<0 or (p->>'waiting_minor')::bigint>o.waiting_minor then
       perform wm.fail('ONLY_WAITING_REDUCTION_ALLOWED'); end if;
     update wm.orders set waiting_minor=(p->>'waiting_minor')::bigint,
      total_minor=transport_minor+booking_minor+(p->>'waiting_minor')::bigint,version=version+1 where orders.id=o.id returning * into o;
   end if;
   perform wm.emit(o.id,action,jsonb_build_object('reason',p->>'reason'));
   return wm.order_result(o);
 elsif action='operator.cash_remittance' then
   select * into pay from wm.payments where payments.id=(p->>'payment_id')::uuid for update;
   if not found or pay.method<>'cash' or pay.status<>'paid' then perform wm.fail('INVALID_PAYMENT'); end if;
   insert into wm.cash_remittances(payment_id,operator_id,reference) values(pay.id,actor,p->>'reference');
 elsif action='operator.resolve_incident' then
   update wm.incidents set status='resolved',resolution=p->>'reason',resolved_by=actor where incidents.id=(p->>'incident_id')::uuid;
   if not found then perform wm.fail('NOT_FOUND'); end if;
 else perform wm.fail('UNKNOWN_COMMAND'); end if;
 perform wm.emit(null,action,p- 'token');
 return jsonb_build_object('updated',true,'id',target_id);
end $$;

create function public.wm_command(p_action text,p_payload jsonb,p_command_key uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare u uuid:=wm.require_actor(); fingerprint text; existing wm.commands; response jsonb; o wm.orders; iid uuid;
begin
 if p_command_key is null or p_action is null or p_payload is null or jsonb_typeof(p_payload)<>'object'
 or octet_length(p_payload::text)>16384 then perform wm.fail('INVALID_COMMAND'); end if;
 fingerprint:=encode(sha256(convert_to(jsonb_build_object('action',p_action,'payload',p_payload)::text,'UTF8')),'hex');
 insert into wm.commands(actor_id,command_key,payload_hash) values(u,p_command_key,fingerprint) on conflict do nothing;
 select * into existing from wm.commands where actor_id=u and command_key=p_command_key for update;
 if existing.payload_hash<>fingerprint then perform wm.fail('IDEMPOTENCY_CONFLICT'); end if;
 if existing.result is not null then return existing.result; end if;
 if p_action like 'operator.%' then response:=wm.cmd_operator(p_action,p_payload);
 elsif p_action in ('booking.submit','booking.cancel','driver.travel','driver.arrive','driver.start_loading','driver.collect','driver.depart','evidence.reserve','evidence.finalize') then
   response:=wm.cmd_order(p_action,p_payload);
 elsif p_action in ('dispatch.offer','dispatch.expire','offer.accept','offer.decline','driver.availability','driver.location','driver.load') then
   response:=wm.cmd_driver(p_action,p_payload);
 elsif p_action like 'payment.%' then response:=wm.cmd_payment(p_action,p_payload);
 elsif p_action like 'handoff.%' then response:=wm.cmd_handoff(p_action,p_payload);
 elsif p_action='profile.update' then
   if length(coalesce(p_payload->>'display_name','')) not between 1 and 120 then perform wm.fail('INVALID_NAME'); end if;
   update wm.profiles set display_name=p_payload->>'display_name' where id=u;
   response:=jsonb_build_object('updated',true);
 elsif p_action='incident.report' then
   if p_payload->>'order_id' is not null then o:=wm.order_locked(p_payload); end if;
   insert into wm.incidents(order_id,reporter_id,kind,details) values(o.id,u,p_payload->>'kind',p_payload->>'details') returning id into iid;
   perform wm.emit(o.id,'incident.reported',jsonb_build_object('incident_id',iid));
   response:=jsonb_build_object('incident_id',iid);
 else perform wm.fail('UNKNOWN_COMMAND'); end if;
 -- Raw QR secrets never persist in command results. A replay tells the caller to rotate.
 update wm.commands set result=case when p_action='handoff.issue' then (response-'token')||'{"refresh_required":true}'::jsonb else response end
 where actor_id=u and command_key=p_command_key;
 return response;
end $$;

create function public.wm_catalog() returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('service_area','East Legon, Accra, Ghana','currency','GHS','booking_minor',100,
 'waiting_rate_minor',90,'waiting_grace_seconds',300,'payment_methods',jsonb_build_array('cash','mtn_momo','telecel_cash'),
 'mobile_money_ready',false,'bookings_enabled',(select bookings_enabled from wm.settings where id),
 'categories',(select jsonb_agg(jsonb_build_object('code',c.code,'enabled',c.enabled,'warehouse_id',c.warehouse_id,
   'receiver_pending',c.warehouse_id is null,'pricing_ready',exists(select 1 from wm.tariffs t where t.category=c.code and t.active))) from wm.categories c),
 'warehouses',(select jsonb_agg(jsonb_build_object('id',w.id,'name',w.name,'address',w.address,
   'reference_latitude',w.reference_latitude,'reference_longitude',w.reference_longitude,
   'location_precision',case when w.entrance_verified then 'verified_entrance' else 'approximate_area' end,
   'entrance_verified',w.entrance_verified,'receiving_enabled',w.receiving_enabled)) from wm.warehouses w))
$$;
create function public.wm_list_orders(p_before timestamptz default null,p_limit integer default 30) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare u uuid:=wm.require_actor(); result jsonb;
begin
 select coalesce(jsonb_agg(wm.order_result(x)),'[]') into result from
 (select o.* from wm.orders o where wm.can_read_order(o.id) and (p_before is null or o.created_at<p_before)
 order by o.created_at desc,o.id desc limit least(greatest(coalesce(p_limit,30),1),100)) x;
 return result;
end $$;
create function public.wm_get_order(p_order_id uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare u uuid:=wm.require_actor(); o wm.orders; result jsonb;
begin
 select * into o from wm.orders where id=p_order_id;
 if not found or not wm.can_read_order(o.id) then perform wm.fail('NOT_FOUND'); end if;
 result:=wm.order_result(o);
 return result||jsonb_build_object('events',(select coalesce(jsonb_agg(jsonb_build_object('id',id,'kind',kind,'created_at',created_at) order by id),'[]') from wm.events where order_id=o.id),
 'evidence',(select coalesce(jsonb_agg(jsonb_build_object('id',id,'purpose',purpose,'path',object_path)),'[]') from wm.evidence where order_id=o.id and finalized));
end $$;
create function public.wm_my_offers() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare u uuid:=wm.require_actor(); result jsonb;
begin
 if not wm.is_driver() then perform wm.fail('FORBIDDEN'); end if;
 select coalesce(jsonb_agg(jsonb_build_object('offer_id',f.id,'order_id',f.order_id,'expires_at',f.expires_at,'category',o.category,
  'area','East Legon')),'[]') into result from wm.offers f join wm.orders o on o.id=f.order_id
 where f.driver_id=u and f.status='offered' and f.expires_at>now();
 return result;
end $$;
create function public.wm_tracking(p_order_id uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare u uuid:=wm.require_actor(); o wm.orders; d wm.drivers; s wm.settings;
begin
 select * into o from wm.orders where id=p_order_id;
 if not found or not wm.can_read_order(o.id) then perform wm.fail('NOT_FOUND'); end if;
 if o.state not in ('accepted','en_route','arrived') then return jsonb_build_object('available',false); end if;
 select * into d from wm.drivers where user_id=o.driver_id;
 select * into s from wm.settings where id;
 if not d.approved or not exists(select 1 from wm.profiles where id=d.user_id and active)
 or s.location_max_age_seconds is null or d.location is null or d.location_at is null
 or d.location_at<=now()-make_interval(secs=>s.location_max_age_seconds) then
 return jsonb_build_object('available',false,'reason','stale_location'); end if;
 return jsonb_build_object('available',true,'latitude',extensions.st_y(d.location),'longitude',extensions.st_x(d.location),
 'measured_at',d.location_at,'accuracy_m',d.accuracy_m);
end $$;
create function public.wm_preview_handoff(p_token text) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare u uuid:=wm.require_actor(); h wm.handoffs; o wm.orders;
begin
 select * into h from wm.handoffs where token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex');
 if not found or not wm.is_receiver(h.warehouse_id) or h.driver_id=u or h.status<>'presented' or h.expires_at<=now() then
 perform wm.fail('INVALID_QR'); end if;
 select * into o from wm.orders where id=h.order_id;
 return jsonb_build_object('handoff_id',h.id,'order_id',o.id,'category',o.category,'collected_at',o.collected_at,
 'warehouse_id',h.warehouse_id,'driver_id',h.driver_id,'expires_at',h.expires_at);
end $$;
create function public.wm_operator_overview() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 perform wm.require_actor();
 if not wm.is_operator() then perform wm.fail('FORBIDDEN'); end if;
 return jsonb_build_object('settings',(select to_jsonb(s) from wm.settings s where id),
 'incidents',(select coalesce(jsonb_agg(to_jsonb(i)),'[]') from (select * from wm.incidents where status='open' order by created_at limit 100) i),
 'drivers',(select coalesce(jsonb_agg(jsonb_build_object('id',d.user_id,'approved',d.approved,'online',d.online,'load_state',d.load_state,'vehicle_id',d.vehicle_id)),'[]') from wm.drivers d),
 'pending_custody',(select count(*) from wm.orders where state='collected' and warehouse_confirmed_at is null),
 'failed_dispatch',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from (select id,order_id,last_error,attempts from wm.outbox where kind='dispatch.requested' and status='dead' order by id limit 100) x),
 'outbox_pending',(select count(*) from wm.outbox where status in ('pending','processing','dead')));
end $$;

create function public.wm_bootstrap_operator(p_user_id uuid) returns void language plpgsql security definer set search_path='' as $$
begin
 if auth.role() is distinct from 'service_role' then perform wm.fail('FORBIDDEN'); end if;
 if not exists(select 1 from wm.profiles where id=p_user_id) then perform wm.fail('ACCOUNT_NOT_FOUND'); end if;
 insert into wm.roles(user_id,role) values(p_user_id,'operator') on conflict do nothing;
 perform wm.emit(null,'operator.bootstrapped',jsonb_build_object('user_id',p_user_id));
end $$;

-- An authenticated operator or trusted worker obtains candidate coordinates, never clients.
create function public.wm_dispatch_candidates(p_order_id uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare o wm.orders; s wm.settings; result jsonb;
begin
 if not wm.is_operator() and auth.role() is distinct from 'service_role' then perform wm.fail('FORBIDDEN'); end if;
 select * into o from wm.orders where id=p_order_id;
 if not found or o.state<>'searching' then perform wm.fail('ORDER_NOT_SEARCHING'); end if;
 if exists(select 1 from wm.offers where order_id=o.id and status='offered' and expires_at>now()) then
   perform wm.fail('OFFER_ALREADY_OPEN'); end if;
 select * into s from wm.settings where id;
 select coalesce(jsonb_agg(jsonb_build_object('driver_id',x.user_id,'latitude',extensions.st_y(x.location),'longitude',extensions.st_x(x.location))),'[]')
 into result from (select d.* from wm.drivers d join wm.profiles pr on pr.id=d.user_id and pr.active
 join wm.vehicles v on v.id=d.vehicle_id and v.active and o.category=any(v.categories)
 where d.approved and d.online and d.load_state in ('available','nearly_full') and d.accuracy_m<=s.arrival_radius_m
 and d.location_at>now()-make_interval(secs=>s.location_max_age_seconds)
 and exists(select 1 from wm.roles where user_id=d.user_id and role='driver')
 and not exists(select 1 from wm.orders active where active.driver_id=d.user_id and active.departed_at is null
   and active.state in ('accepted','en_route','arrived','loading','collected'))
 and not exists(select 1 from wm.offers f where f.driver_id=d.user_id and f.status='offered' and f.expires_at>now())
 and not exists(select 1 from wm.offers f where f.driver_id=d.user_id and f.order_id=o.id and f.status in ('declined','expired'))
 order by extensions.st_distance(d.location::extensions.geography,o.pickup::extensions.geography) limit 5) x;
 return jsonb_build_object('order_id',o.id,'candidates',result,'destination',jsonb_build_object('latitude',extensions.st_y(o.pickup),'longitude',extensions.st_x(o.pickup)));
end $$;

create function public.wm_claim_outbox(p_limit integer default 20) returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 if auth.role() is distinct from 'service_role' then perform wm.fail('FORBIDDEN'); end if;
 update wm.outbox set status='dead',last_error='RETRY_LIMIT' where attempts>=5 and status in ('pending','processing') and (lease_until is null or lease_until<now());
 with picked as (select id from wm.outbox where attempts<5 and available_at<=now()
 and (status='pending' or (status='processing' and lease_until<now())) order by id for update skip locked limit least(greatest(p_limit,1),100)),
 claimed as (update wm.outbox set status='processing',attempts=attempts+1,lease_until=now()+interval '60 seconds',lease_token=gen_random_uuid()
 where id in (select id from picked) returning *) select coalesce(jsonb_agg(to_jsonb(claimed)),'[]') into result from claimed;
 return result;
end $$;
create function public.wm_finish_outbox(p_id bigint,p_lease_token uuid,p_success boolean,p_error text default null) returns void
language plpgsql security definer set search_path='' as $$
begin
 if auth.role() is distinct from 'service_role' then perform wm.fail('FORBIDDEN'); end if;
 update wm.outbox set status=case when p_success then 'done' when attempts>=5 then 'dead' else 'pending' end,
 available_at=now()+make_interval(secs=>least(3600,30*power(2,attempts)::integer)),lease_until=null,lease_token=null,
 last_error=case when p_success then null else left(p_error,200) end
 where id=p_id and lease_token=p_lease_token and status='processing' and lease_until>now();
 if not found then perform wm.fail('LEASE_CONFLICT'); end if;
end $$;

revoke all on all functions in schema wm from public,anon,authenticated;
grant execute on function wm.is_operator(),wm.is_driver(),wm.can_read_order(uuid),wm.can_upload(text),wm.can_download(text) to authenticated;
do $$ declare f record; begin
 for f in select p.oid::regprocedure as signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname like 'wm_%' loop
 execute format('revoke all on function %s from public, anon, authenticated',f.signature);
 end loop;
end $$;
grant execute on function public.wm_catalog() to anon,authenticated;
grant execute on function public.wm_command(text,jsonb,uuid), public.wm_prepare_quote(text,double precision,double precision),
 public.wm_list_orders(timestamptz,integer), public.wm_get_order(uuid),public.wm_my_offers(),public.wm_tracking(uuid),
 public.wm_preview_handoff(text),public.wm_operator_overview(),public.wm_dispatch_candidates(uuid) to authenticated;
grant execute on function public.wm_finish_quote(uuid,integer,integer),public.wm_bootstrap_operator(uuid),
 public.wm_claim_outbox(integer),public.wm_finish_outbox(bigint,uuid,boolean,text) to service_role;
-- Future private helpers must not accidentally inherit PUBLIC execution.
alter default privileges in schema wm revoke execute on functions from public;
