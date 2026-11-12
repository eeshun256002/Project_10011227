-- Synthetic fixtures exist only inside this transaction. Never commit this file.
begin;
do $$
declare c uuid:=gen_random_uuid(); d uuid:=gen_random_uuid(); op uuid:=gen_random_uuid(); r uuid:=gen_random_uuid();
 w uuid; q jsonb; o jsonb; offer jsonb; qr jsonb; p jsonb; response jsonb; caught boolean;
begin
 insert into auth.users(id,email_confirmed_at) values(c,now()),(d,now()),(op,now()),(r,now());
 insert into wm.client_profiles(user_id,full_name) values(c,'ROLLBACK Client');
 insert into wm.driver_applications(user_id,full_name,vehicle_plate,status) values(d,'ROLLBACK Driver','TEST-'||replace(d::text,'-',''),'approved');
 insert into wm.driver_documents(application_id,kind,object_path,uploaded_by,content_type,document_number,license_class,expires_on,vehicle_plate,uploaded_at,review_status)
 select a.id,k,'ROLLBACK/'||gen_random_uuid()::text,d,'image/jpeg','TEST','TEST',current_date+365,a.vehicle_plate,now(),'approved'
 from wm.driver_applications a cross join unnest(array['driving_license','profile_photo','vehicle_insurance','roadworthiness']) k where a.user_id=d;
 perform set_config('request.jwt.claim.sub','',true);
 perform set_config('request.jwt.claim.role','service_role',true);
 perform public.wm_bootstrap_operator(op);
 perform set_config('request.jwt.claim.role','authenticated',true);
 perform set_config('request.jwt.claim.sub',op::text,true);
 select id into w from wm.warehouses where code='coliba_lapaz';
 perform public.wm_command('operator.settings','{"reason":"ROLLBACK TEST","bookings_enabled":true,"quote_ttl_seconds":600,"offer_ttl_seconds":60,"location_max_age_seconds":120,"arrival_radius_m":100,"waiting_rounding":"pro_rata","qr_ttl_seconds":300}',gen_random_uuid());
 perform public.wm_command('operator.warehouse',jsonb_build_object('reason','ROLLBACK TEST','warehouse_id',w,'latitude',5.60601,'longitude',-0.24717,'entrance_verified',true,'receiving_enabled',true,'receiving_hours','TEST','material_restrictions','TEST'),gen_random_uuid());
 perform public.wm_command('operator.category','{"reason":"ROLLBACK TEST","category":"non_biodegradable","enabled":true}',gen_random_uuid());
 perform public.wm_command('operator.tariff','{"reason":"ROLLBACK TEST","category":"non_biodegradable","tariff_version":"ROLLBACK TEST","per_km_minor":100,"per_travel_minute_minor":10}',gen_random_uuid());
 perform public.wm_command('operator.area','{"reason":"ROLLBACK TEST","geojson":{"type":"Polygon","coordinates":[[[-0.2,5.6],[-0.1,5.6],[-0.1,5.7],[-0.2,5.7],[-0.2,5.6]]]}}',gen_random_uuid());
 perform public.wm_command('operator.driver',jsonb_build_object('reason','ROLLBACK TEST','user_id',d,'plate','TEST-'||replace(d::text,'-','')),gen_random_uuid());
 perform public.wm_command('operator.receiver',jsonb_build_object('reason','ROLLBACK TEST','user_id',r,'warehouse_id',w),gen_random_uuid());
 perform set_config('request.jwt.claim.sub',d::text,true);
 perform public.wm_command('driver.availability','{"online":true}',gen_random_uuid());
 perform public.wm_command('driver.location',jsonb_build_object('latitude',5.64,'longitude',-0.16,'accuracy_m',5,'sequence',1,'measured_at',clock_timestamp()),gen_random_uuid());
 perform set_config('request.jwt.claim.sub',c::text,true);
 q:=public.wm_prepare_quote('non_biodegradable',5.64,-0.16);
 perform set_config('request.jwt.claim.role','service_role',true);
 q:=public.wm_finish_quote((q->>'intent_id')::uuid,10000,1200);
 if (q->>'transport_minor')::integer<>1200 then raise exception 'SMOKE_PRICE_FAILED'; end if;
 perform set_config('request.jwt.claim.role','authenticated',true);
 o:=public.wm_command('booking.submit',jsonb_build_object('quote_id',q->>'quote_id','address','ROLLBACK TEST'),gen_random_uuid());
 perform set_config('request.jwt.claim.role','service_role',true);
 offer:=public.wm_worker_offer((o->>'id')::uuid,d);
 perform set_config('request.jwt.claim.role','authenticated',true);
 perform set_config('request.jwt.claim.sub',d::text,true);
 o:=public.wm_command('offer.accept',jsonb_build_object('offer_id',offer->>'offer_id'),gen_random_uuid());
 if public.wm_driver_status()->>'location_sequence'<>'1' then raise exception 'SMOKE_DRIVER_RESTORE_FAILED'; end if;
 if jsonb_array_length(public.wm_active_orders('driver'))<>1 then raise exception 'SMOKE_ACTIVE_READ_FAILED'; end if;
 perform set_config('request.jwt.claim.sub',c::text,true);
 response:=public.wm_order_presentation((o->>'id')::uuid);
 if response->'driver'->>'display_name'<>'ROLLBACK Driver' then raise exception 'SMOKE_DRIVER_CARD_FAILED'; end if;
 response:=public.wm_eta_context((o->>'id')::uuid);
 if (response->'origin'->>'latitude')::numeric<>5.64 then raise exception 'SMOKE_ETA_CONTEXT_FAILED'; end if;
 if jsonb_array_length(public.wm_updates())<1 then raise exception 'SMOKE_UPDATES_FAILED'; end if;
 perform set_config('request.jwt.claim.sub',d::text,true);
 o:=public.wm_command('driver.travel',jsonb_build_object('order_id',o->>'id','version',o->'version'),gen_random_uuid());
 o:=public.wm_command('driver.arrive',jsonb_build_object('order_id',o->>'id','version',o->'version'),gen_random_uuid());
 update wm.orders set arrived_at=clock_timestamp()-interval '8 minutes' where id=(o->>'id')::uuid;
 o:=public.wm_command('driver.start_loading',jsonb_build_object('order_id',o->>'id','version',o->'version'),gen_random_uuid());
 if (o->>'waiting_minor')::integer<>270 then raise exception 'SMOKE_WAITING_FAILED'; end if;
 -- Object bytes belong to the Storage API. This SQL smoke test seeds metadata only.
 p:=public.wm_command('evidence.reserve',jsonb_build_object('order_id',o->>'id','version',o->'version','purpose','pickup'),gen_random_uuid());
 insert into storage.objects(bucket_id,name,owner_id) values(p->>'bucket',p->>'path',d::text);
 perform public.wm_command('evidence.finalize',jsonb_build_object('evidence_id',p->>'evidence_id'),gen_random_uuid());
 o:=public.wm_command('driver.collect',jsonb_build_object('order_id',o->>'id','version',o->'version'),gen_random_uuid());
 caught:=false;
 begin
  perform public.wm_command('driver.depart',jsonb_build_object('order_id',o->>'id','version',o->'version'),gen_random_uuid());
 exception when raise_exception then if sqlerrm<>'PAYMENT_REQUIRED' then raise; end if; caught:=true; end;
 if not caught then raise exception 'SMOKE_PAYMENT_GATE_FAILED'; end if;
 perform public.wm_command('payment.cash',jsonb_build_object('order_id',o->>'id','version',o->'version','amount_minor',o->'total_minor'),gen_random_uuid());
 o:=public.wm_command('driver.depart',jsonb_build_object('order_id',o->>'id','version',o->'version'),gen_random_uuid());
 qr:=public.wm_command('handoff.issue',jsonb_build_object('order_id',o->>'id','version',o->'version'),gen_random_uuid());
 perform set_config('request.jwt.claim.sub',r::text,true);
 perform public.wm_preview_handoff(qr->>'token');
 response:=public.wm_command('handoff.confirm',jsonb_build_object('token',qr->>'token','outcome','confirmed'),gen_random_uuid());
 if response->>'outcome'<>'confirmed' then raise exception 'SMOKE_HANDOFF_FAILED'; end if;
 perform set_config('request.jwt.claim.sub',c::text,true);
 response:=public.wm_order_presentation((o->>'id')::uuid);
 if response->'handoffs'->0->>'status'<>'confirmed' then raise exception 'SMOKE_PRESENTATION_FAILED'; end if;
 if jsonb_array_length(public.wm_active_orders('client'))<>0 then raise exception 'SMOKE_COMPLETED_ACTIVE_FAILED'; end if;
 perform set_config('request.jwt.claim.sub',r::text,true);
 caught:=false;
 begin
  perform public.wm_command('handoff.confirm',jsonb_build_object('token',qr->>'token','outcome','confirmed'),gen_random_uuid());
 exception when raise_exception then if sqlerrm<>'QR_EXPIRED_OR_USED' then raise; end if; caught:=true; end;
 if not caught then raise exception 'SMOKE_QR_REPLAY_FAILED'; end if;
 if has_function_privilege('anon','public.wm_command(text,jsonb,uuid)','EXECUTE') then raise exception 'SMOKE_ANON_GRANT_FAILED'; end if;
 if has_function_privilege('authenticated','public.wm_worker_offer(uuid,uuid)','EXECUTE') then raise exception 'SMOKE_WORKER_GRANT_FAILED'; end if;
 if exists(select 1 from pg_class cl join pg_namespace n on n.oid=cl.relnamespace where n.nspname='wm' and cl.relkind='r' and not cl.relrowsecurity) then raise exception 'SMOKE_RLS_FAILED'; end if;
end $$;
rollback;
select json_build_object('hosted_transaction_smoke','passed','fixtures','rolled back',
 'bookings_enabled',(select bookings_enabled from wm.settings),
 'tariff_count',(select count(*) from wm.tariffs),
 'order_count',(select count(*) from wm.orders),
 'auth_user_count',(select count(*) from auth.users)) as verification;
