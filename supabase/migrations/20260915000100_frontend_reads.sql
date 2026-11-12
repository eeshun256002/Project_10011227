-- Explicit, scoped frontend reads. No table exposure or live-service activation.
create function public.wm_driver_status() returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare u uuid:=wm.require_actor(); d wm.drivers; v wm.vehicles;
begin
 if not wm.is_driver() then perform wm.fail('FORBIDDEN'); end if;
 select * into d from wm.drivers where user_id=u;
 select * into v from wm.vehicles where id=d.vehicle_id;
 return jsonb_build_object('user_id',u,'online',d.online,'load_state',d.load_state,
   'vehicle',jsonb_build_object('id',v.id,'plate',v.plate,'active',v.active),
   'can_take_jobs',wm.driver_eligible(u,d.vehicle_id),
   'location_sequence',d.location_sequence,'location_measured_at',d.location_at,
   'server_time',now());
end $$;

create function public.wm_staff_access() returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare u uuid:=wm.require_actor();
begin
 return jsonb_build_object('operator',wm.is_operator(),
   'warehouses',(select coalesce(jsonb_agg(jsonb_build_object('id',w.id,'name',w.name) order by w.id),'[]')
     from wm.warehouses w where wm.is_receiver(w.id)));
end $$;

create function public.wm_order_presentation(p_order_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare u uuid:=wm.require_actor(); o wm.orders;
begin
 select * into o from wm.orders where id=p_order_id;
 if not found or not wm.can_read_order(o.id) then perform wm.fail('NOT_FOUND'); end if;
 return jsonb_build_object('order',wm.order_result(o),
   'driver',(select jsonb_build_object('display_name',coalesce(nullif(p.display_name,''),a.full_name),
     'plate',v.plate) from wm.drivers d join wm.profiles p on p.id=d.user_id
     left join wm.driver_applications a on a.user_id=d.user_id
     left join wm.vehicles v on v.id=o.vehicle_id where d.user_id=o.driver_id),
   'payments',(select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'method',p.method,
     'amount_minor',p.amount_minor,'currency',p.currency,'status',p.status,'recorded_at',p.created_at)
     order by p.created_at,p.id),'[]') from wm.payments p where p.order_id=o.id),
   'handoffs',(select coalesce(jsonb_agg(jsonb_build_object('id',h.id,'status',h.status,
     'reason',h.reason,'confirmed_at',h.confirmed_at,'created_at',h.created_at) order by h.created_at,h.id),'[]')
     from wm.handoffs h where h.order_id=o.id),
   'server_time',now());
end $$;

-- Stable composite cursor; independent of history, so older custody is not lost.
create function public.wm_active_orders(p_app text,p_before timestamptz default null,
 p_before_id uuid default null,p_limit integer default 30) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare u uuid:=wm.require_actor(); result jsonb;
begin
 if p_app is null or p_app not in ('client','driver') then perform wm.fail('INVALID_APP'); end if;
 if p_app='driver' and not wm.is_driver() then perform wm.fail('FORBIDDEN'); end if;
 if (p_before is null)<>(p_before_id is null) then perform wm.fail('INVALID_CURSOR'); end if;
 select coalesce(jsonb_agg(wm.order_result(x) order by x.created_at desc,x.id desc),'[]') into result
 from (select o.* from wm.orders o where
   ((p_app='client' and o.client_id=u) or (p_app='driver' and o.driver_id=u))
   and o.state not in ('cancelled','failed') and o.warehouse_confirmed_at is null
   and (p_before is null or (o.created_at,o.id)<(p_before,p_before_id))
   order by o.created_at desc,o.id desc limit least(greatest(coalesce(p_limit,30),1),100)) x;
 return result;
end $$;

-- Only a currently authorized, fresh approach location can be used for ETA.
create function public.wm_eta_context(p_order_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare u uuid:=wm.require_actor(); o wm.orders; tracking jsonb;
begin
 select * into o from wm.orders where id=p_order_id;
 if not found or not wm.can_read_order(o.id) then perform wm.fail('NOT_FOUND'); end if;
 if o.state not in ('accepted','en_route') then perform wm.fail('ETA_UNAVAILABLE'); end if;
 tracking:=public.wm_tracking(o.id);
 if not coalesce((tracking->>'available')::boolean,false) then perform wm.fail('STALE_LOCATION'); end if;
 return jsonb_build_object('order_id',o.id,'version',o.version,
   'origin',jsonb_build_object('latitude',tracking->'latitude','longitude',tracking->'longitude'),
   'destination',jsonb_build_object('latitude',extensions.st_y(o.pickup),'longitude',extensions.st_x(o.pickup)),
   'location_measured_at',tracking->'measured_at');
end $$;

-- Foreground catch-up feed. Payloads (including internal dispatch metadata)
-- are deliberately omitted. This is not a push-delivery acknowledgment.
create function public.wm_updates(p_after_id bigint default 0,p_limit integer default 50) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare u uuid:=wm.require_actor(); result jsonb;
begin
 if p_after_id is null or p_after_id<0 then perform wm.fail('INVALID_CURSOR'); end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',x.id,'order_id',x.order_id,
   'kind',x.kind,'created_at',x.created_at) order by x.id),'[]') into result
 from (select e.id,e.order_id,e.kind,e.created_at from wm.events e
   where e.id>p_after_id and e.order_id is not null and wm.can_read_order(e.order_id)
   and e.kind in ('dispatch.requested','booking.cancelled','offer.accepted',
     'driver.travel','driver.arrive','driver.start_loading','driver.collect','driver.depart',
     'payment.cash_attested','handoff.confirmed','handoff.partial','handoff.rejected','operator.fail_visit')
   order by e.id limit least(greatest(coalesce(p_limit,50),1),100)) x;
 return result;
end $$;

revoke all on function public.wm_updates(bigint,integer) from public,anon,authenticated;
grant execute on function public.wm_updates(bigint,integer) to authenticated;

revoke all on function public.wm_driver_status(),public.wm_staff_access(),
 public.wm_order_presentation(uuid),public.wm_active_orders(text,timestamptz,uuid,integer),
 public.wm_eta_context(uuid) from public,anon,authenticated;
grant execute on function public.wm_driver_status(),public.wm_staff_access(),
 public.wm_order_presentation(uuid),public.wm_active_orders(text,timestamptz,uuid,integer),
 public.wm_eta_context(uuid) to authenticated;
