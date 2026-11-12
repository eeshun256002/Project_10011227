-- PGlite runs the domain migrations; hosted Supabase supplies pg_cron/pg_net/Vault.
do $$ begin
 if exists(select 1 from pg_available_extensions where name='pg_cron')
 and exists(select 1 from pg_available_extensions where name='pg_net') then
   create extension if not exists pg_cron;
   create extension if not exists pg_net with schema extensions;
 end if;
end $$;

create function wm.invoke_dispatch_worker() returns bigint language plpgsql security definer set search_path='' as $$
declare endpoint text; token text; request_id bigint;
begin
 if not (select bookings_enabled from wm.settings where id) then return null; end if;
 if not exists(select 1 from wm.outbox where kind='dispatch.requested' and status in ('pending','processing') and available_at<=now())
 and not exists(select 1 from wm.offers where status='offered' and expires_at<=now()) then return null; end if;
 select decrypted_secret into endpoint from vault.decrypted_secrets where name='wm_worker_url';
 select decrypted_secret into token from vault.decrypted_secrets where name='wm_worker_secret';
 if endpoint is null or endpoint !~ '^https://[a-z0-9]+[.]supabase[.]co/functions/v1/wm-worker$'
 or length(coalesce(token,''))<32 then return null; end if;
 select net.http_post(url=>endpoint,headers=>jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||token),
   body=>'{}'::jsonb,timeout_milliseconds=>100000) into request_id;
 return request_id;
end $$;
revoke all on function wm.invoke_dispatch_worker() from public,anon,authenticated,service_role;
do $$ begin
 if exists(select 1 from pg_extension where extname='pg_cron') and exists(select 1 from pg_extension where extname='pg_net') then
   perform cron.schedule('wm-dispatch-worker','30 seconds','select wm.invoke_dispatch_worker()');
 end if;
end $$;
