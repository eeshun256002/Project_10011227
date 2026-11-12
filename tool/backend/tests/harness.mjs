import { PGlite } from '@electric-sql/pglite';
import { postgis } from '@electric-sql/pglite-postgis';
import { readFile, readdir } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
export const root = fileURLToPath(new URL('../../../', import.meta.url));
export async function database() {
  const db = new PGlite({extensions:{postgis}});
  // Supabase-owned schemas are emulated; application migrations are unmodified.
  await db.exec(`
    create role anon; create role authenticated; create role service_role bypassrls;
    create schema auth; create schema storage;
    create table auth.users(id uuid primary key,email_confirmed_at timestamptz,phone_confirmed_at timestamptz);
    create function auth.uid() returns uuid language sql stable as
      $$ select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
    create function auth.role() returns text language sql stable as
      $$ select nullif(current_setting('request.jwt.claim.role',true),'') $$;
    grant usage on schema auth to authenticated,anon,service_role;
    grant execute on all functions in schema auth to authenticated,anon,service_role;
    create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);
    create table storage.objects(id uuid default gen_random_uuid(),bucket_id text,name text,owner_id text,metadata jsonb);
    alter table storage.objects enable row level security;
    grant usage on schema storage to authenticated;
    grant select,insert,update,delete on storage.objects to authenticated;
  `);
  for (const file of (await readdir(root+'supabase/migrations')).sort()) {
    if(file.endsWith('.sql')) await db.exec(await readFile(root+'supabase/migrations/'+file,'utf8'));
  }
  return db;
}
export async function asUser(db,id,sql,params=[]) {
  return db.transaction(async tx=>{
    await tx.exec('set local role authenticated');
    await tx.query("select set_config('request.jwt.claim.sub',$1,true),set_config('request.jwt.claim.role','authenticated',true)",[id]);
    return tx.query(sql,params);
  });
}
export async function command(db,id,action,payload,key=crypto.randomUUID()) {
 const r=await asUser(db,id,'select public.wm_command($1,$2::jsonb,$3::uuid) as result',[action,JSON.stringify(payload),key]);
 return r.rows[0].result;
}

// Synthetic approved documents for older operational regression tests only.
// Onboarding-specific tests use the actual upload/review RPCs instead.
export async function approvedDriverFixture(db,user,plate) {
 const a=(await db.query("insert into wm.driver_applications(user_id,full_name,vehicle_plate,status) values($1,'TEST Driver',$2,'approved') returning id",[user,plate])).rows[0].id;
 for(const kind of ['driving_license','profile_photo','vehicle_insurance','roadworthiness']) {
  await db.query(`insert into wm.driver_documents(application_id,kind,object_path,uploaded_by,content_type,document_number,license_class,expires_on,vehicle_plate,uploaded_at,review_status)
   values($1,$2,$3,$4,'image/jpeg','TEST','TEST',current_date+365,$5,now(),'approved')`,[a,kind,'TEST/'+crypto.randomUUID(),user,plate]);
 }
}
