-- Read-only catalogue audit. No keys, credentials or personal record contents.
select jsonb_build_object(
 'checked_at',now(),
 'tables',(select jsonb_agg(jsonb_build_object('name',c.relname,'rls',c.relrowsecurity,'owner',pg_get_userbyid(c.relowner))) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='wm' and c.relkind='r'),
 'rpc_permissions',(select jsonb_agg(jsonb_build_object('signature',p.oid::regprocedure::text,'definer',p.prosecdef,'settings',p.proconfig,
  'anon_execute',has_function_privilege('anon',p.oid,'execute'),'user_execute',has_function_privilege('authenticated',p.oid,'execute'),
  'service_execute',has_function_privilege('service_role',p.oid,'execute'))) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname like 'wm_%'),
 'unsafe_definer_paths',(select coalesce(jsonb_agg(p.oid::regprocedure::text),'[]') from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where (n.nspname='wm' or (n.nspname='public' and p.proname like 'wm_%')) and p.prosecdef and not coalesce(p.proconfig @> array['search_path=""'],false)),
 'direct_user_writes',(select coalesce(jsonb_agg(c.relname),'[]') from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='wm' and c.relkind='r'
  and (has_table_privilege('authenticated',c.oid,'insert') or has_table_privilege('authenticated',c.oid,'update') or has_table_privilege('authenticated',c.oid,'delete'))),
 'unindexed_foreign_keys',(select coalesce(jsonb_agg(jsonb_build_object('table',con.conrelid::regclass::text,'constraint',con.conname,
  'columns',(select jsonb_agg(att.attname order by key.ordinality) from unnest(con.conkey) with ordinality as key(attnum,ordinality) join pg_attribute att on att.attrelid=con.conrelid and att.attnum=key.attnum))),'[]')
  from pg_constraint con join pg_namespace n on n.oid=con.connamespace where n.nspname='wm' and con.contype='f'
  and not exists(select 1 from pg_index i where i.indrelid=con.conrelid and i.indisvalid and i.indpred is null
    and con.conkey <@ (i.indkey::smallint[])[0:cardinality(con.conkey)-1])),
 'policies',(select jsonb_agg(jsonb_build_object('table',tablename,'name',policyname,'roles',roles,'command',cmd,'using',qual,'check',with_check)) from pg_policies where schemaname='wm' or (schemaname='storage' and policyname like '%wm%') or (schemaname='storage' and policyname like 'driver_document%')),
 'incidents',jsonb_build_object('check','available','open',(select count(*) from wm.incidents where status='open')),
 'dispatch_dead_letters',(select count(*) from wm.outbox where kind='dispatch.requested' and status='dead'),
 'bookings_enabled',(select bookings_enabled from wm.settings),
 'data_counts',jsonb_build_object('users',(select count(*) from auth.users),'orders',(select count(*) from wm.orders)),
 'cron',(select jsonb_agg(jsonb_build_object('name',jobname,'active',active,'schedule',schedule)) from cron.job where jobname like 'wm-%')
) as health;
