-- Index actual relationships and hot lookups identified by the hosted audit.
create index payments_order_history on wm.payments(order_id,created_at desc,id desc);
create index offers_order_driver_status on wm.offers(order_id,driver_id,status);
create index evidence_order_purpose on wm.evidence(order_id,purpose);
create index documents_application_history on wm.driver_documents(application_id,created_at);
create index reviews_application_history on wm.driver_application_reviews(application_id,created_at);
create index outbox_order_kind_status on wm.outbox(order_id,kind,status);
create index incidents_order_kind_status on wm.incidents(order_id,kind,status);
create index incidents_status_created on wm.incidents(status,created_at);
create index offers_expiration on wm.offers(expires_at) where status='offered';
create index outbox_due_dispatch on wm.outbox(available_at,id) where kind='dispatch.requested' and status in ('pending','processing');
-- Cover remaining FK lookups without duplicating existing complete indexes.
do $$ declare c record; cols text; begin
 for c in select con.conrelid,con.conkey,cl.relname from pg_constraint con join pg_class cl on cl.oid=con.conrelid
 join pg_namespace n on n.oid=con.connamespace where n.nspname='wm' and con.contype='f'
 and not exists(select 1 from pg_index i where i.indrelid=con.conrelid and i.indisvalid and i.indpred is null
   and con.conkey <@ (i.indkey::smallint[])[0:cardinality(con.conkey)-1]) loop
   select string_agg(quote_ident(a.attname),',' order by k.ordinality) into cols
   from unnest(c.conkey) with ordinality k(attnum,ordinality) join pg_attribute a on a.attrelid=c.conrelid and a.attnum=k.attnum;
   execute format('create index %I on wm.%I (%s)','fk_'||c.relname||'_'||array_to_string(c.conkey,'_'),c.relname,cols);
 end loop;
end $$;

-- These helpers only read state / raise deterministic errors; annotate correctly.
alter function wm.require_actor() stable;
alter function wm.fail(text) immutable;

-- Cache caller-only policy checks once per statement. Row-dependent checks remain per row.
create function wm.actor_active() returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from wm.profiles where id=auth.uid() and active)
$$;
revoke all on function wm.actor_active() from public,anon,authenticated;
grant execute on function wm.actor_active() to authenticated;
alter policy profile_read on wm.profiles using((select wm.actor_active()) and (id=(select auth.uid()) or (select wm.is_operator())));
alter policy client_profile_read on wm.client_profiles using((select wm.actor_active()) and (user_id=(select auth.uid()) or (select wm.is_operator())));
alter policy incident_read on wm.incidents using((select wm.actor_active()) and (reporter_id=(select auth.uid()) or (select wm.is_operator())));
alter policy offer_read on wm.offers using((driver_id=(select auth.uid()) and (select wm.is_driver())) or (select wm.is_operator()));
alter policy order_read on wm.orders using((select wm.actor_active()) and
 (client_id=(select auth.uid()) or (select wm.is_operator()) or (driver_id=(select auth.uid()) and (select wm.is_driver()) and state not in ('failed','cancelled'))));
alter policy application_read on wm.driver_applications using((select wm.actor_active()) and (user_id=(select auth.uid()) or (select wm.is_operator())));
alter policy driver_document_upload on storage.objects with check(bucket_id='wm-driver-documents' and owner_id=(select auth.uid())::text and wm.can_upload_driver_document(name));

-- Replace the per-result order re-query in the history API with indexed ownership predicates.
create or replace function public.wm_list_orders(p_before timestamptz default null,p_limit integer default 30) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare u uuid:=wm.require_actor(); is_op boolean:=wm.is_operator(); is_driver boolean:=wm.is_driver(); result jsonb;
begin
 select coalesce(jsonb_agg(wm.order_result(x) order by x.created_at desc,x.id desc),'[]') into result from
 (select o.* from wm.orders o where (is_op or o.client_id=u or (is_driver and o.driver_id=u and o.state not in ('failed','cancelled')))
 and (p_before is null or o.created_at<p_before) order by o.created_at desc,o.id desc limit least(greatest(coalesce(p_limit,30),1),100)) x;
 return result;
end $$;

-- Retired implementation helpers do not belong in the exposed RPC schema.
drop function public.wm_dispatch_candidates_before_onboarding(uuid);
alter function public.wm_prepare_quote_before_onboarding(text,double precision,double precision) set schema wm;
alter function wm.wm_prepare_quote_before_onboarding(text,double precision,double precision) rename to prepare_quote_impl;
create or replace function public.wm_prepare_quote(p_category text,p_latitude double precision,p_longitude double precision) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 if not exists(select 1 from wm.client_profiles where user_id=wm.require_actor()) then perform wm.fail('CLIENT_REGISTRATION_REQUIRED'); end if;
 return wm.prepare_quote_impl(p_category,p_latitude,p_longitude);
end $$;
revoke all on function wm.prepare_quote_impl(text,double precision,double precision) from public,anon,authenticated,service_role;

-- Prevent future application helpers inheriting permissive PUBLIC execution.
-- This does not change existing functions or expand the exposed schemas.
-- A schema-scoped REVOKE alone cannot remove the global default PUBLIC grant.
alter default privileges revoke execute on functions from public,anon,authenticated;
alter default privileges in schema public revoke execute on functions from public,anon,authenticated;

-- Correct the evidence upload/read policy pairing: the uploader may read a
-- reserved object before finalization, as required by Storage INSERT RETURNING.
create or replace function wm.can_download(path text) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from wm.evidence e where e.object_path=path and wm.can_read_order(e.order_id)
 and (e.finalized or e.uploader_id=auth.uid()))
$$;
