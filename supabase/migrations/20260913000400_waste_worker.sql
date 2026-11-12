-- Service-only dispatch entry points. No service secret belongs in the Flutter app.
create function public.wm_worker_offer(p_order_id uuid,p_driver_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 if auth.role() is distinct from 'service_role' then perform wm.fail('FORBIDDEN'); end if;
 return wm.cmd_driver('dispatch.offer',jsonb_build_object('order_id',p_order_id,'driver_id',p_driver_id));
end $$;
create function public.wm_worker_sweep() returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if auth.role() is distinct from 'service_role' then perform wm.fail('FORBIDDEN'); end if;
 return wm.cmd_driver('dispatch.expire','{}');
end $$;
create function public.wm_claim_dispatch(p_limit integer default 5) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 if auth.role() is distinct from 'service_role' then perform wm.fail('FORBIDDEN'); end if;
 update wm.outbox set status='dead',last_error='DISPATCH_RETRY_LIMIT' where kind='dispatch.requested'
 and attempts>=5 and status in ('pending','processing') and (lease_until is null or lease_until<now());
 with picked as (select id from wm.outbox where kind='dispatch.requested' and attempts<5 and available_at<=now()
 and (status='pending' or (status='processing' and lease_until<now())) order by id for update skip locked limit least(greatest(coalesce(p_limit,5),1),10)),
 claimed as (update wm.outbox set status='processing',attempts=attempts+1,lease_until=now()+interval '120 seconds',lease_token=gen_random_uuid()
 where id in (select id from picked) returning *) select coalesce(jsonb_agg(to_jsonb(claimed)),'[]') into result from claimed;
 return result;
end $$;
-- Full trucks need the verified receiving destination, never a made-up route.
create function public.wm_driver_destination() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare u uuid:=wm.require_actor(); w wm.warehouses;
begin
 if not wm.is_driver() then perform wm.fail('FORBIDDEN'); end if;
 if exists(select 1 from wm.orders where driver_id=u and departed_at is null and state in ('accepted','en_route','arrived','loading','collected')) then
   perform wm.fail('ACTIVE_PICKUP_REQUIRES_RESOLUTION'); end if;
 select * into w from wm.warehouses where id=(select warehouse_id from wm.categories where code='non_biodegradable');
 if not w.entrance_verified or not w.receiving_enabled or w.routing_point is null then perform wm.fail('WAREHOUSE_NOT_READY'); end if;
 return jsonb_build_object('warehouse_id',w.id,'name',w.name,'address',w.address,
 'latitude',extensions.st_y(w.routing_point),'longitude',extensions.st_x(w.routing_point));
end $$;
revoke all on function public.wm_worker_offer(uuid,uuid),public.wm_worker_sweep(),public.wm_claim_dispatch(integer),public.wm_driver_destination() from public,anon,authenticated;
grant execute on function public.wm_worker_offer(uuid,uuid),public.wm_worker_sweep(),public.wm_claim_dispatch(integer),public.wm_dispatch_candidates(uuid) to service_role;
grant execute on function public.wm_driver_destination() to authenticated;
