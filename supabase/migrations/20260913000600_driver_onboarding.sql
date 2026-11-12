-- Separate app enrollment; both apps share Supabase Auth, never password tables.
create table wm.client_profiles (
 user_id uuid primary key references wm.profiles(id),
 full_name text not null check(length(btrim(full_name)) between 2 and 120),
 created_at timestamptz not null default now()
);
create table wm.driver_applications (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null unique references wm.profiles(id),
 full_name text not null check(length(btrim(full_name)) between 2 and 120),
 date_of_birth date,
 residential_address text not null default '' check(length(residential_address)<=500),
 emergency_contact_name text not null default '' check(length(emergency_contact_name)<=120),
 emergency_contact_phone text not null default '' check(emergency_contact_phone='' or emergency_contact_phone ~ '^\+[1-9][0-9]{7,14}$'),
 vehicle_plate text not null check(length(vehicle_plate) between 3 and 40),
 vehicle_make text not null default '' check(length(vehicle_make)<=80),
 vehicle_model text not null default '' check(length(vehicle_model)<=80),
 status text not null default 'draft' check(status in ('draft','submitted','changes_requested','approved','rejected')),
 version integer not null default 1,
 submitted_at timestamptz,
 reviewed_at timestamptz,
 reviewed_by uuid references wm.profiles(id),
 review_reason text,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
create table wm.driver_documents (
 id uuid primary key default gen_random_uuid(),
 application_id uuid not null references wm.driver_applications(id),
 kind text not null check(kind in ('driving_license','profile_photo','vehicle_insurance','roadworthiness','ghana_card')),
 object_path text not null unique,
 uploaded_by uuid not null references wm.profiles(id),
 content_type text not null check(content_type in ('image/jpeg','image/png','image/webp','application/pdf')),
 document_number text check(length(document_number) between 1 and 120),
 issuing_country text not null default 'GH' check(issuing_country='GH'),
 license_class text check(length(license_class) between 1 and 30),
 issued_on date,
 expires_on date,
 vehicle_plate text,
 uploaded_at timestamptz,
 is_current boolean not null default true,
 review_status text not null default 'pending' check(review_status in ('pending','approved','rejected','revoked')),
 reviewed_by uuid references wm.profiles(id),
 reviewed_at timestamptz,
 review_reason text,
 created_at timestamptz not null default now(),
 check(kind<>'profile_photo' or content_type<>'application/pdf'),
 check(kind<>'driving_license' or (document_number is not null and license_class is not null and expires_on is not null)),
 check(kind not in ('vehicle_insurance','roadworthiness') or (expires_on is not null and vehicle_plate is not null)),
 check(issued_on is null or expires_on is null or issued_on<=expires_on)
);
create unique index current_driver_document on wm.driver_documents(application_id,kind) where is_current;
create index driver_application_queue on wm.driver_applications(status,submitted_at);
create table wm.driver_application_reviews (
 id uuid primary key default gen_random_uuid(),
 application_id uuid not null references wm.driver_applications(id),
 document_id uuid references wm.driver_documents(id),
 reviewer_id uuid not null references wm.profiles(id),
 decision text not null check(decision in ('approved','rejected','changes_requested','revoked')),
 reason text not null check(length(reason) between 3 and 2000),
 application_version integer not null,
 created_at timestamptz not null default now()
);
do $$ declare t text; begin
 foreach t in array array['client_profiles','driver_applications','driver_documents','driver_application_reviews'] loop
 execute format('alter table wm.%I enable row level security',t);
 execute format('revoke all on wm.%I from public,anon,authenticated',t);
 execute format('grant select on wm.%I to authenticated',t);
 execute format('grant all on wm.%I to service_role',t);
 end loop;
end $$;

create function wm.can_read_application(aid uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from wm.driver_applications a join wm.profiles p on p.id=auth.uid() and p.active
 where a.id=aid and (a.user_id=auth.uid() or wm.is_operator()))
$$;
create policy client_profile_read on wm.client_profiles for select to authenticated using(user_id=auth.uid() or wm.is_operator());
create policy application_read on wm.driver_applications for select to authenticated using(wm.can_read_application(id));
create policy driver_document_read on wm.driver_documents for select to authenticated using(wm.can_read_application(application_id));
create policy driver_review_read on wm.driver_application_reviews for select to authenticated using(wm.can_read_application(application_id));
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
 values('wm-driver-documents','wm-driver-documents',false,10485760,array['image/jpeg','image/png','image/webp','application/pdf']);
create function wm.can_upload_driver_document(path text) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from wm.driver_documents d join wm.driver_applications a on a.id=d.application_id
 join wm.profiles p on p.id=a.user_id and p.active
 where d.object_path=path and a.user_id=auth.uid() and d.uploaded_by=auth.uid() and d.is_current
 and d.uploaded_at is null and a.status in ('draft','changes_requested'))
$$;
create function wm.can_read_driver_document(path text) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from wm.driver_documents d where d.object_path=path and wm.can_read_application(d.application_id))
$$;
create policy driver_document_upload on storage.objects for insert to authenticated
 with check(bucket_id='wm-driver-documents' and owner_id=auth.uid()::text and wm.can_upload_driver_document(name));
create policy driver_document_download on storage.objects for select to authenticated
 using(bucket_id='wm-driver-documents' and wm.can_read_driver_document(name));
-- No public URLs, applicant UPDATE/DELETE, or firm upload: drivers supply documents.

create function wm.application_ready(aid uuid,require_approval boolean) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from wm.driver_applications a where a.id=aid
 and (not require_approval or a.status='approved')
 and not exists(select 1 from unnest(array['driving_license','profile_photo','vehicle_insurance','roadworthiness']) as required(kind)
 where not exists(select 1 from wm.driver_documents d where d.application_id=a.id and d.kind=required.kind and d.is_current
 and d.uploaded_at is not null and (not require_approval or d.review_status='approved')
 and (d.issued_on is null or d.issued_on<=current_date)
 and (d.expires_on is null or d.expires_on>=current_date)
 and (d.kind not in ('vehicle_insurance','roadworthiness') or d.vehicle_plate=a.vehicle_plate))))
$$;
create function wm.driver_eligible(uid uuid,vid uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from wm.driver_applications a join wm.vehicles v on v.plate=a.vehicle_plate
 join wm.profiles p on p.id=a.user_id and p.active
 where a.user_id=uid and v.id=vid and v.active and wm.application_ready(a.id,true))
$$;
create function wm.application_result(aid uuid) returns jsonb language sql stable set search_path='' as $$
 select to_jsonb(a)||jsonb_build_object('documents',
 (select coalesce(jsonb_agg(to_jsonb(d) order by d.created_at),'[]') from wm.driver_documents d where d.application_id=a.id and d.is_current),
 'review_history',(select coalesce(jsonb_agg(to_jsonb(r) order by r.created_at),'[]') from wm.driver_application_reviews r where r.application_id=a.id),
 'required_documents',jsonb_build_array('driving_license','profile_photo','vehicle_insurance','roadworthiness'),
 'optional_documents',jsonb_build_array('ghana_card'),'requirements_current',wm.application_ready(a.id,true))
 from wm.driver_applications a where a.id=aid
$$;

create function public.wm_onboarding_command(p_action text,p_payload jsonb,p_command_key uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare u uuid:=wm.require_actor(); a wm.driver_applications; d wm.driver_documents; existing wm.commands;
 fingerprint text; response jsonb; p jsonb:=p_payload; outcome text; reason text; content text;
begin
 if p_command_key is null or p_action is null or p is null or jsonb_typeof(p)<>'object' or octet_length(p::text)>16384 then perform wm.fail('INVALID_COMMAND'); end if;
 fingerprint:=encode(sha256(convert_to(jsonb_build_object('domain','onboarding','action',p_action,'payload',p)::text,'UTF8')),'hex');
 insert into wm.commands(actor_id,command_key,payload_hash) values(u,p_command_key,fingerprint) on conflict do nothing;
 select * into existing from wm.commands where actor_id=u and command_key=p_command_key for update;
 if existing.payload_hash<>fingerprint then perform wm.fail('IDEMPOTENCY_CONFLICT'); end if;
 if existing.result is not null then return existing.result; end if;
 -- Serializes creation, document changes, submission and decisions per applicant.
 if p_action like 'operator.%' then
   if not wm.is_operator() then perform wm.fail('FORBIDDEN'); end if;
   select * into a from wm.driver_applications where id=(p->>'application_id')::uuid for update;
   if not found then perform wm.fail('NOT_FOUND'); end if;
   if a.user_id=u then perform wm.fail('SELF_REVIEW_FORBIDDEN'); end if;
 else
   perform 1 from wm.profiles where id=u for update;
   select * into a from wm.driver_applications where user_id=u for update;
 end if;
 if p_action='client.register' then
   if length(btrim(coalesce(p->>'full_name',''))) not between 2 and 120 then perform wm.fail('FULL_NAME_REQUIRED'); end if;
   insert into wm.client_profiles(user_id,full_name) values(u,btrim(p->>'full_name'))
   on conflict(user_id) do update set full_name=excluded.full_name;
   response:=jsonb_build_object('client_registered',true);
 elsif p_action='application.save' then
   if a.id is not null and (p->>'version' is null or (p->>'version')::integer<>a.version) then perform wm.fail('VERSION_CONFLICT'); end if;
   if a.id is not null and a.status not in ('draft','changes_requested') then perform wm.fail('APPLICATION_LOCKED'); end if;
   if length(btrim(coalesce(p->>'full_name',''))) not between 2 and 120 then perform wm.fail('FULL_NAME_REQUIRED'); end if;
   if length(btrim(coalesce(p->>'vehicle_plate',''))) not between 3 and 40 then perform wm.fail('VEHICLE_PLATE_REQUIRED'); end if;
   if (p->>'date_of_birth')::date>=current_date then perform wm.fail('INVALID_DATE_OF_BIRTH'); end if;
   insert into wm.driver_applications(user_id,full_name,date_of_birth,residential_address,emergency_contact_name,emergency_contact_phone,vehicle_plate,vehicle_make,vehicle_model)
   values(u,btrim(p->>'full_name'),(p->>'date_of_birth')::date,coalesce(p->>'residential_address',''),coalesce(p->>'emergency_contact_name',''),coalesce(p->>'emergency_contact_phone',''),upper(btrim(p->>'vehicle_plate')),coalesce(p->>'vehicle_make',''),coalesce(p->>'vehicle_model',''))
   on conflict(user_id) do update set full_name=excluded.full_name,date_of_birth=excluded.date_of_birth,
   residential_address=excluded.residential_address,emergency_contact_name=excluded.emergency_contact_name,
   emergency_contact_phone=excluded.emergency_contact_phone,vehicle_plate=excluded.vehicle_plate,
   vehicle_make=excluded.vehicle_make,vehicle_model=excluded.vehicle_model,version=driver_applications.version+1,updated_at=now()
   returning * into a;
   response:=wm.application_result(a.id);
 else
   if a.id is null then perform wm.fail('APPLICATION_REQUIRED'); end if;
   if p->>'version' is null or (p->>'version')::integer<>a.version then perform wm.fail('VERSION_CONFLICT'); end if;
   if p_action in ('document.reserve','document.finalize') then
     if a.status not in ('draft','changes_requested') then perform wm.fail('APPLICATION_LOCKED'); end if;
     if p_action='document.reserve' then
       if p->>'kind' is null or p->>'kind' not in ('driving_license','profile_photo','vehicle_insurance','roadworthiness','ghana_card') then perform wm.fail('INVALID_DOCUMENT_KIND'); end if;
       content:=p->>'content_type';
       if content is null or content not in ('image/jpeg','image/png','image/webp','application/pdf')
       or (p->>'kind'='profile_photo' and content='application/pdf') then perform wm.fail('INVALID_DOCUMENT_TYPE'); end if;
       if (p->>'expires_on')::date<current_date or (p->>'issued_on')::date>current_date then perform wm.fail('DOCUMENT_NOT_CURRENT'); end if;
       if p->>'kind' in ('driving_license','vehicle_insurance','roadworthiness') and p->>'expires_on' is null then perform wm.fail('DOCUMENT_EXPIRY_REQUIRED'); end if;
       if p->>'kind'='driving_license' and (nullif(btrim(p->>'document_number'),'') is null or nullif(btrim(p->>'license_class'),'') is null) then perform wm.fail('LICENSE_DETAILS_REQUIRED'); end if;
       if coalesce(p->>'issuing_country','GH')<>'GH' then perform wm.fail('GHANAIAN_DOCUMENT_REQUIRED'); end if;
       update wm.driver_documents set is_current=false where application_id=a.id and kind=p->>'kind' and is_current;
       insert into wm.driver_documents(application_id,kind,object_path,uploaded_by,content_type,document_number,license_class,issued_on,expires_on,vehicle_plate)
       values(a.id,p->>'kind',u::text||'/'||a.id::text||'/'||gen_random_uuid()::text,u,content,
       nullif(btrim(p->>'document_number'),''),nullif(btrim(p->>'license_class'),''),(p->>'issued_on')::date,(p->>'expires_on')::date,
       case when p->>'kind' in ('vehicle_insurance','roadworthiness') then a.vehicle_plate else null end) returning * into d;
       response:=jsonb_build_object('document_id',d.id,'bucket','wm-driver-documents','path',d.object_path);
     else
       select * into d from wm.driver_documents where id=(p->>'document_id')::uuid and application_id=a.id and is_current for update;
       if not found or d.uploaded_by<>u then perform wm.fail('NOT_FOUND'); end if;
       if not exists(select 1 from storage.objects where bucket_id='wm-driver-documents' and name=d.object_path
       and owner_id=u::text and metadata->>'mimetype'=d.content_type and (metadata->>'size')::bigint between 1 and 10485760) then perform wm.fail('VALID_UPLOAD_REQUIRED'); end if;
       update wm.driver_documents set uploaded_at=coalesce(uploaded_at,clock_timestamp()) where id=d.id;
       response:=jsonb_build_object('document_id',d.id,'uploaded',true);
     end if;
   elsif p_action='application.submit' then
     if a.status not in ('draft','changes_requested') then perform wm.fail('APPLICATION_LOCKED'); end if;
     if not wm.application_ready(a.id,false) then perform wm.fail('REQUIRED_DOCUMENTS_MISSING_OR_EXPIRED'); end if;
     update wm.driver_applications set status='submitted',submitted_at=clock_timestamp() where id=a.id;
     response:=jsonb_build_object('submitted',true);
   elsif p_action='application.reopen' then
     if a.status not in ('approved','rejected') then perform wm.fail('APPLICATION_LOCKED'); end if;
     update wm.driver_applications set status='draft' where id=a.id;
     response:=jsonb_build_object('draft',true);
   elsif p_action='operator.review_document' then
     outcome:=p->>'decision';reason:=p->>'reason';
     if outcome is null or outcome not in ('approved','rejected','revoked') or length(coalesce(reason,'')) not between 3 and 2000 then perform wm.fail('REVIEW_DECISION_AND_REASON_REQUIRED'); end if;
     if a.status<>'submitted' and outcome<>'revoked' then perform wm.fail('APPLICATION_NOT_SUBMITTED'); end if;
     select * into d from wm.driver_documents where id=(p->>'document_id')::uuid and application_id=a.id and is_current for update;
     if not found or d.uploaded_at is null then perform wm.fail('VALID_UPLOAD_REQUIRED'); end if;
     if outcome='approved' and ((d.expires_on is not null and d.expires_on<current_date) or (d.issued_on is not null and d.issued_on>current_date)
       or (d.kind in ('vehicle_insurance','roadworthiness') and d.vehicle_plate<>a.vehicle_plate)) then perform wm.fail('DOCUMENT_NOT_CURRENT'); end if;
     update wm.driver_documents set review_status=outcome,reviewed_by=u,reviewed_at=clock_timestamp(),review_reason=reason where id=d.id;
     insert into wm.driver_application_reviews(application_id,document_id,reviewer_id,decision,reason,application_version)
     values(a.id,d.id,u,outcome,reason,a.version);
     if outcome in ('rejected','revoked') then update wm.driver_applications set status='changes_requested' where id=a.id; end if;
     response:=jsonb_build_object('document_id',d.id,'decision',outcome);
   elsif p_action='operator.review_application' then
     outcome:=p->>'decision';reason:=p->>'reason';
     if outcome is null or outcome not in ('approved','rejected','changes_requested') or length(coalesce(reason,'')) not between 3 and 2000 then perform wm.fail('REVIEW_DECISION_AND_REASON_REQUIRED'); end if;
     if a.status<>'submitted' then perform wm.fail('APPLICATION_NOT_SUBMITTED'); end if;
     if outcome='approved' then
       if not wm.application_ready(a.id,false) or exists(select 1 from wm.driver_documents where application_id=a.id and is_current and kind in ('driving_license','profile_photo','vehicle_insurance','roadworthiness') and review_status<>'approved') then perform wm.fail('DOCUMENT_REVIEW_REQUIRED'); end if;
     end if;
     update wm.driver_applications set status=outcome,reviewed_by=u,reviewed_at=clock_timestamp(),review_reason=reason where id=a.id;
     insert into wm.driver_application_reviews(application_id,reviewer_id,decision,reason,application_version) values(a.id,u,outcome,reason,a.version);
     -- Employee and vehicle provisioning is separate; approval alone never silently assigns a truck.
     response:=jsonb_build_object('decision',outcome);
   else perform wm.fail('UNKNOWN_COMMAND'); end if;
   update wm.driver_applications set version=version+1,updated_at=now() where id=a.id returning * into a;
   response:=response||jsonb_build_object('application_id',a.id,'version',a.version,'status',a.status);
 end if;
 -- Personal details and document numbers stay out of the general event/outbox stream.
 perform wm.emit(null,'onboarding.'||p_action,jsonb_build_object('application_id',a.id));
 update wm.commands set result=response where actor_id=u and command_key=p_command_key;
 return response;
end $$;

create function public.wm_my_driver_application() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare u uuid:=wm.require_actor(); aid uuid;
begin select id into aid from wm.driver_applications where user_id=u; return wm.application_result(aid); end $$;
create function public.wm_driver_application(p_application_id uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 perform wm.require_actor();
 if not wm.can_read_application(p_application_id) then perform wm.fail('NOT_FOUND'); end if;
 return wm.application_result(p_application_id);
end $$;
create function public.wm_driver_application_queue(p_status text default 'submitted') returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 perform wm.require_actor();if not wm.is_operator() then perform wm.fail('FORBIDDEN'); end if;
 return (select coalesce(jsonb_agg(to_jsonb(a)),'[]') from (select id,user_id,full_name,vehicle_plate,status,version,submitted_at from wm.driver_applications where status=p_status order by submitted_at nulls last,id limit 100) a);
end $$;
create function public.wm_account_access() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare u uuid:=wm.require_actor();
begin
 return jsonb_build_object('user_id',u,'client_registered',exists(select 1 from wm.client_profiles where user_id=u),
 'driver_application_status',(select status from wm.driver_applications where user_id=u),
 'driver_provisioned',wm.is_driver(),
 'driver_can_take_jobs',wm.is_driver() and coalesce((select wm.driver_eligible(u,vehicle_id) from wm.drivers where user_id=u),false));
end $$;

-- Enforce review even through the pre-existing firm provisioning command.
create function wm.check_driver_provisioning() returns trigger language plpgsql set search_path='' as $$
begin
 if new.approved and not wm.driver_eligible(new.user_id,new.vehicle_id) then perform wm.fail('DRIVER_DOCUMENT_APPROVAL_REQUIRED'); end if;
 return new;
end $$;
create trigger approved_driver_documents before insert or update of approved,vehicle_id on wm.drivers
 for each row execute function wm.check_driver_provisioning();

-- Ongoing custody actions remain available; expiry/revocation blocks NEW jobs.
alter function wm.cmd_driver(text,jsonb) rename to cmd_driver_before_onboarding;
create function wm.cmd_driver(action text,p jsonb) returns jsonb language plpgsql set search_path='' as $$
declare d wm.drivers; aid uuid;
begin
 if action in ('dispatch.offer','offer.accept') or (action='driver.availability' and (p->>'online')::boolean) then
   if action='dispatch.offer' then select * into d from wm.drivers where user_id=(p->>'driver_id')::uuid;
   else select * into d from wm.drivers where user_id=auth.uid(); end if;
   -- Serialize acceptance with changes/revocation of the application documents.
   select id into aid from wm.driver_applications where user_id=d.user_id for share;
   if not wm.driver_eligible(d.user_id,d.vehicle_id) then perform wm.fail('DRIVER_DOCUMENT_APPROVAL_REQUIRED'); end if;
 end if;
 return wm.cmd_driver_before_onboarding(action,p);
end $$;
alter function public.wm_dispatch_candidates(uuid) rename to wm_dispatch_candidates_before_onboarding;
create function public.wm_dispatch_candidates(p_order_id uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare o wm.orders; s wm.settings; result jsonb;
begin
 if not wm.is_operator() and auth.role() is distinct from 'service_role' then perform wm.fail('FORBIDDEN'); end if;
 select * into o from wm.orders where id=p_order_id;
 if not found or o.state<>'searching' then perform wm.fail('ORDER_NOT_SEARCHING'); end if;
 if exists(select 1 from wm.offers where order_id=o.id and status='offered' and expires_at>now()) then perform wm.fail('OFFER_ALREADY_OPEN'); end if;
 select * into s from wm.settings where id;
 select coalesce(jsonb_agg(jsonb_build_object('driver_id',x.user_id,'latitude',extensions.st_y(x.location),'longitude',extensions.st_x(x.location))),'[]')
 into result from (select d.* from wm.drivers d join wm.profiles pr on pr.id=d.user_id and pr.active
 join wm.vehicles v on v.id=d.vehicle_id and v.active and o.category=any(v.categories)
 where d.approved and d.online and d.load_state in ('available','nearly_full') and d.accuracy_m<=s.arrival_radius_m
 and d.location_at>now()-make_interval(secs=>s.location_max_age_seconds)
 and wm.driver_eligible(d.user_id,d.vehicle_id)
 and exists(select 1 from wm.roles where user_id=d.user_id and role='driver')
 and not exists(select 1 from wm.orders active where active.driver_id=d.user_id and active.departed_at is null and active.state in ('accepted','en_route','arrived','loading','collected'))
 and not exists(select 1 from wm.offers f where f.driver_id=d.user_id and f.status='offered' and f.expires_at>now())
 and not exists(select 1 from wm.offers f where f.driver_id=d.user_id and f.order_id=o.id and f.status in ('declined','expired'))
 order by extensions.st_distance(d.location::extensions.geography,o.pickup::extensions.geography) limit 5) x;
 return jsonb_build_object('order_id',o.id,'candidates',result,'destination',jsonb_build_object('latitude',extensions.st_y(o.pickup),'longitude',extensions.st_x(o.pickup)));
end $$;
-- The previous entry point is no longer callable by API roles.
revoke all on function public.wm_dispatch_candidates_before_onboarding(uuid) from public,anon,authenticated,service_role;
revoke all on function wm.cmd_driver_before_onboarding(text,jsonb),wm.cmd_driver(text,jsonb),wm.check_driver_provisioning(),
 wm.application_ready(uuid,boolean),wm.driver_eligible(uuid,uuid),wm.application_result(uuid),
 wm.can_read_application(uuid),wm.can_upload_driver_document(text),wm.can_read_driver_document(text) from public,anon,authenticated;
grant execute on function wm.can_read_application(uuid),wm.can_upload_driver_document(text),wm.can_read_driver_document(text) to authenticated;
revoke all on function public.wm_onboarding_command(text,jsonb,uuid),public.wm_my_driver_application(),public.wm_driver_application(uuid),
 public.wm_driver_application_queue(text),public.wm_account_access(),public.wm_dispatch_candidates(uuid) from public,anon,authenticated;
grant execute on function public.wm_onboarding_command(text,jsonb,uuid),public.wm_my_driver_application(),public.wm_driver_application(uuid),
 public.wm_driver_application_queue(text),public.wm_account_access(),public.wm_dispatch_candidates(uuid) to authenticated;
grant execute on function public.wm_dispatch_candidates(uuid) to service_role;

-- Explicit client enrollment belongs to the client app, not to driver signup.
insert into wm.client_profiles(user_id,full_name)
 select distinct o.client_id,coalesce(nullif(btrim(p.display_name),''),'Existing client') from wm.orders o join wm.profiles p on p.id=o.client_id
 on conflict do nothing;
alter function public.wm_prepare_quote(text,double precision,double precision) rename to wm_prepare_quote_before_onboarding;
create function public.wm_prepare_quote(p_category text,p_latitude double precision,p_longitude double precision) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 if not exists(select 1 from wm.client_profiles where user_id=wm.require_actor()) then perform wm.fail('CLIENT_REGISTRATION_REQUIRED'); end if;
 return public.wm_prepare_quote_before_onboarding(p_category,p_latitude,p_longitude);
end $$;
revoke all on function public.wm_prepare_quote_before_onboarding(text,double precision,double precision) from public,anon,authenticated,service_role;
revoke all on function public.wm_prepare_quote(text,double precision,double precision) from public,anon,authenticated;
grant execute on function public.wm_prepare_quote(text,double precision,double precision) to authenticated;
