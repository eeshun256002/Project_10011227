-- Transaction-only fixtures. No document bytes, messages or real identities.
begin;
do $$
declare applicant uuid:=gen_random_uuid(); reviewer uuid:=gen_random_uuid(); a jsonb; d jsonb; k text;
 doc record; response jsonb; caught boolean;
begin
 insert into auth.users(id,email_confirmed_at) values(applicant,now()),(reviewer,now());
 insert into wm.roles(user_id,role) values(reviewer,'operator');
 perform set_config('request.jwt.claim.role','authenticated',true);
 perform set_config('request.jwt.claim.sub',applicant::text,true);
 a:=public.wm_onboarding_command('application.save',jsonb_build_object('full_name','ROLLBACK Driver','vehicle_plate','TEST-'||upper(replace(applicant::text,'-',''))),gen_random_uuid());
 if public.wm_account_access()->>'driver_can_take_jobs'<>'false' then raise exception 'SMOKE_EARLY_ACCESS'; end if;
 foreach k in array array['driving_license','profile_photo','vehicle_insurance','roadworthiness'] loop
   d:=public.wm_onboarding_command('document.reserve',jsonb_build_object('version',a->'version','kind',k,'content_type','image/jpeg',
      'document_number','TEST','license_class','TEST','expires_on',current_date+365),gen_random_uuid());
   a:=public.wm_my_driver_application();
   insert into storage.objects(bucket_id,name,owner_id,metadata) values(d->>'bucket',d->>'path',applicant::text,'{"mimetype":"image/jpeg","size":2048}');
   perform public.wm_onboarding_command('document.finalize',jsonb_build_object('version',a->'version','document_id',d->>'document_id'),gen_random_uuid());
   a:=public.wm_my_driver_application();
 end loop;
 perform public.wm_onboarding_command('application.submit',jsonb_build_object('version',a->'version'),gen_random_uuid());
 a:=public.wm_my_driver_application();
 perform set_config('request.jwt.claim.sub',reviewer::text,true);
 caught:=false;
 begin
   perform public.wm_onboarding_command('operator.review_application',jsonb_build_object('application_id',a->>'id','version',a->'version','decision','approved','reason','ROLLBACK TEST'),gen_random_uuid());
 exception when raise_exception then if sqlerrm<>'DOCUMENT_REVIEW_REQUIRED' then raise; end if; caught:=true; end;
 if not caught then raise exception 'SMOKE_REVIEW_BYPASS'; end if;
 for doc in select id from wm.driver_documents where application_id=(a->>'id')::uuid and is_current loop
   perform public.wm_onboarding_command('operator.review_document',jsonb_build_object('application_id',a->>'id','version',a->'version',
      'document_id',doc.id,'decision','approved','reason','ROLLBACK manual verification'),gen_random_uuid());
   a:=public.wm_driver_application((a->>'id')::uuid);
 end loop;
 perform public.wm_onboarding_command('operator.review_application',jsonb_build_object('application_id',a->>'id','version',a->'version',
      'decision','approved','reason','ROLLBACK manual verification'),gen_random_uuid());
 perform public.wm_command('operator.driver',jsonb_build_object('user_id',applicant,'plate',a->>'vehicle_plate','reason','ROLLBACK TEST'),gen_random_uuid());
 perform set_config('request.jwt.claim.sub',applicant::text,true);
 if public.wm_account_access()->>'driver_can_take_jobs'<>'true' then raise exception 'SMOKE_APPROVAL_FAILED'; end if;
 update wm.driver_documents set expires_on=current_date-1 where application_id=(a->>'id')::uuid and kind='vehicle_insurance';
 if public.wm_account_access()->>'driver_can_take_jobs'<>'false' then raise exception 'SMOKE_EXPIRY_FAILED'; end if;
 if has_function_privilege('anon','public.wm_onboarding_command(text,jsonb,uuid)','execute') then raise exception 'SMOKE_GRANTS_FAILED'; end if;
 if has_table_privilege('authenticated','wm.driver_documents','update') then raise exception 'SMOKE_DOCUMENT_GRANTS_FAILED'; end if;
 if (select public from storage.buckets where id='wm-driver-documents') then raise exception 'SMOKE_PUBLIC_DOCUMENTS'; end if;
end $$;
rollback;
select json_build_object('onboarding_smoke','passed','fixtures','rolled back',
 'application_count',(select count(*) from wm.driver_applications),
 'document_count',(select count(*) from wm.driver_documents),
 'auth_user_count',(select count(*) from auth.users)) as verification;
