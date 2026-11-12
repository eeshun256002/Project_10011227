-- Private data schema; only explicitly granted public RPCs are exposed.
create schema if not exists extensions;
create extension if not exists postgis with schema extensions;
create schema wm;
revoke all on schema wm from public;
grant usage on schema wm to authenticated, service_role;

create table wm.profiles (
  id uuid primary key references auth.users(id),
  display_name text not null default '' check (length(display_name) <= 120),
  active boolean not null default true,
  preferences jsonb not null default '{}',
  created_at timestamptz not null default now()
);
create table wm.roles (
  user_id uuid references wm.profiles(id),
  role text check (role in ('operator','driver','receiver')),
  primary key(user_id,role)
);
create table wm.settings (
  id boolean primary key default true check (id),
  bookings_enabled boolean not null default false,
  quote_ttl_seconds integer check (quote_ttl_seconds between 60 and 3600),
  offer_ttl_seconds integer check (offer_ttl_seconds between 15 and 300),
  location_max_age_seconds integer check (location_max_age_seconds between 15 and 600),
  arrival_radius_m integer check (arrival_radius_m between 20 and 500),
  waiting_rounding text check (waiting_rounding in ('pro_rata','ceil_minute')),
  qr_ttl_seconds integer check (qr_ttl_seconds between 30 and 900)
);
insert into wm.settings(id) values(true);
create table wm.service_areas (
  id text primary key,
  name text not null,
  boundary extensions.geometry(MultiPolygon,4326),
  verified boolean not null default false,
  check (not verified or (boundary is not null and extensions.st_isvalid(boundary)))
);
insert into wm.service_areas(id,name) values('east_legon','East Legon, Accra, Ghana');
create table wm.warehouses (
  id uuid primary key default gen_random_uuid(),
  code text unique not null,
  name text not null,
  address text not null,
  reference_latitude double precision,
  reference_longitude double precision,
  routing_point extensions.geometry(Point,4326),
  entrance_verified boolean not null default false,
  receiving_enabled boolean not null default false,
  receiving_hours text,
  material_restrictions text,
  check (not entrance_verified or routing_point is not null)
);
insert into wm.warehouses(code,name,address,reference_latitude,reference_longitude)
values('coliba_lapaz','Coliba Ghana / Lapaz Buyback Center',
 'House No. 25, Dela Avenue, adjacent NHIS office, Abeka Lapaz, Accra',5.60601,-0.24717);
create table wm.categories (
  code text primary key check (code in ('biodegradable','non_biodegradable')),
  warehouse_id uuid references wm.warehouses(id),
  enabled boolean not null default false
);
insert into wm.categories(code,warehouse_id)
select 'non_biodegradable',id from wm.warehouses where code='coliba_lapaz';
insert into wm.categories(code) values('biodegradable');
create table wm.receiver_memberships (
  user_id uuid references wm.profiles(id),
  warehouse_id uuid references wm.warehouses(id),
  primary key(user_id,warehouse_id)
);
create table wm.vehicles (
  id uuid primary key default gen_random_uuid(),
  plate text not null unique,
  active boolean not null default true,
  categories text[] not null default array['non_biodegradable']::text[]
    check (categories <@ array['biodegradable','non_biodegradable']::text[])
);
create table wm.drivers (
  user_id uuid primary key references wm.profiles(id),
  vehicle_id uuid unique references wm.vehicles(id),
  approved boolean not null default false,
  online boolean not null default false,
  load_state text not null default 'unknown' check(load_state in ('available','nearly_full','full','unknown')),
  location extensions.geometry(Point,4326),
  location_at timestamptz,
  location_received_at timestamptz,
  accuracy_m numeric check(accuracy_m between 0 and 10000),
  location_sequence bigint not null default -1
);
create table wm.tariffs (
  id uuid primary key default gen_random_uuid(),
  category text not null references wm.categories(code),
  version text not null,
  per_km_minor numeric(12,4) not null check(per_km_minor>=0),
  per_travel_minute_minor numeric(12,4) not null check(per_travel_minute_minor>=0),
  min_transport_minor bigint not null default 0 check(min_transport_minor>=0),
  active boolean not null default false,
  created_at timestamptz not null default now(),
  unique(category,version),
  check(per_km_minor>0 or per_travel_minute_minor>0)
);
create unique index one_active_tariff on wm.tariffs(category) where active;
-- Intentionally NO transport tariffs, area polygon, or routing entrance seeded.
create table wm.quote_intents (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references wm.profiles(id),
  category text not null references wm.categories(code),
  pickup extensions.geometry(Point,4326) not null,
  warehouse_id uuid not null references wm.warehouses(id),
  destination extensions.geometry(Point,4326) not null,
  tariff_id uuid not null references wm.tariffs(id),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null
);
create index quote_intent_owner_time on wm.quote_intents(client_id,created_at);
create table wm.quotes (
  id uuid primary key references wm.quote_intents(id),
  distance_m integer not null check(distance_m between 1 and 1000000),
  duration_s integer not null check(duration_s between 1 and 172800),
  transport_minor bigint not null check(transport_minor>=0),
  source text not null check(source='google_routes'),
  created_at timestamptz not null default now()
);
create table wm.orders (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references wm.profiles(id),
  quote_id uuid unique not null references wm.quotes(id),
  category text not null references wm.categories(code),
  warehouse_id uuid not null references wm.warehouses(id),
  pickup extensions.geometry(Point,4326) not null,
  address text not null check(length(address) between 3 and 500),
  access_note text not null default '' check(length(access_note)<=2000),
  state text not null default 'searching' check(state in
    ('searching','accepted','en_route','arrived','loading','collected','cancelled','failed')),
  driver_id uuid references wm.drivers(user_id),
  vehicle_id uuid references wm.vehicles(id),
  version integer not null default 1,
  arrived_at timestamptz,
  ready_at timestamptz,
  collected_at timestamptz,
  departed_at timestamptz,
  departure_override_reason text,
  warehouse_confirmed_at timestamptz,
  transport_minor bigint not null check(transport_minor>=0),
  booking_minor integer not null default 100 check(booking_minor=100),
  waiting_rate_minor integer not null default 90 check(waiting_rate_minor=90),
  waiting_rounding text not null check(waiting_rounding in ('pro_rata','ceil_minute')),
  waiting_minor bigint check(waiting_minor>=0),
  total_minor bigint check(total_minor>=100),
  replacement_of uuid unique references wm.orders(id),
  created_at timestamptz not null default now()
);
create index orders_owner on wm.orders(client_id,created_at,id);
create index orders_driver on wm.orders(driver_id,created_at);
create index orders_warehouse on wm.orders(warehouse_id);
create unique index one_active_driver_visit on wm.orders(driver_id)
 where driver_id is not null and departed_at is null and state in ('accepted','en_route','arrived','loading','collected');
create table wm.offers (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references wm.orders(id),
  driver_id uuid not null references wm.drivers(user_id),
  status text not null default 'offered' check(status in ('offered','accepted','declined','expired','revoked')),
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);
create unique index one_open_offer_order on wm.offers(order_id) where status='offered';
create unique index one_open_offer_driver on wm.offers(driver_id) where status='offered';
create index offers_driver on wm.offers(driver_id);
create table wm.evidence (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references wm.orders(id),
  uploader_id uuid not null references wm.profiles(id),
  purpose text not null check(purpose in ('pickup','incident','warehouse')),
  object_path text not null unique,
  finalized boolean not null default false,
  created_at timestamptz not null default now()
);
create table wm.payments (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references wm.orders(id),
  method text not null check(method in ('cash','mtn_momo','telecel_cash')),
  amount_minor bigint not null check(amount_minor>0),
  currency text not null default 'GHS' check(currency='GHS'),
  status text not null check(status in ('pending','paid','failed','reversed','refunded')),
  attested_by uuid references wm.profiles(id),
  integration_provider text,
  merchant_reference text,
  provider_reference text unique,
  created_at timestamptz not null default now()
);
create unique index one_unresolved_payment on wm.payments(order_id) where status in ('pending','paid');
create table wm.payment_events (
  id uuid primary key default gen_random_uuid(),
  payment_id uuid not null references wm.payments(id),
  event_reference text not null unique,
  status text not null,
  created_at timestamptz not null default now()
);
create table wm.cash_remittances (
  payment_id uuid primary key references wm.payments(id),
  operator_id uuid not null references wm.profiles(id),
  reference text not null,
  created_at timestamptz not null default now()
);
create table wm.handoffs (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references wm.orders(id),
  driver_id uuid not null references wm.drivers(user_id),
  warehouse_id uuid not null references wm.warehouses(id),
  token_hash text not null unique,
  status text not null default 'presented' check(status in ('presented','confirmed','partial','rejected','revoked')),
  expires_at timestamptz not null,
  receiver_id uuid references wm.profiles(id),
  reason text,
  confirmed_at timestamptz,
  created_at timestamptz not null default now()
);
create unique index one_live_handoff on wm.handoffs(order_id) where status='presented';
create unique index one_final_handoff on wm.handoffs(order_id) where status='confirmed';
create table wm.incidents (
  id uuid primary key default gen_random_uuid(),
  order_id uuid references wm.orders(id),
  reporter_id uuid not null references wm.profiles(id),
  kind text not null check(length(kind) between 3 and 80),
  details text not null check(length(details) between 3 and 4000),
  status text not null default 'open' check(status in ('open','resolved')),
  resolution text,
  resolved_by uuid references wm.profiles(id),
  created_at timestamptz not null default now()
);
create table wm.events (
  id bigint generated always as identity primary key,
  order_id uuid references wm.orders(id),
  actor_id uuid,
  kind text not null,
  data jsonb not null default '{}',
  created_at timestamptz not null default now()
);
create index events_order on wm.events(order_id,id);
create table wm.outbox (
  id bigint generated always as identity primary key,
  order_id uuid references wm.orders(id),
  kind text not null,
  payload jsonb not null default '{}',
  attempts integer not null default 0,
  available_at timestamptz not null default now(),
  lease_until timestamptz,
  lease_token uuid,
  status text not null default 'pending' check(status in ('pending','processing','done','dead')),
  last_error text,
  created_at timestamptz not null default now()
);
create index outbox_ready on wm.outbox(status,available_at);
create table wm.commands (
  actor_id uuid not null,
  command_key uuid not null,
  payload_hash text not null,
  result jsonb,
  created_at timestamptz not null default now(),
  primary key(actor_id,command_key)
);

create function wm.is_operator() returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from wm.roles r join wm.profiles p on p.id=r.user_id
 where r.user_id=auth.uid() and r.role='operator' and p.active)
$$;
create function wm.is_driver() returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from wm.roles r join wm.profiles p on p.id=r.user_id join wm.drivers d on d.user_id=p.id
 where r.user_id=auth.uid() and r.role='driver' and p.active and d.approved)
$$;
create function wm.is_receiver(w uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from wm.roles r join wm.profiles p on p.id=r.user_id
 join wm.receiver_memberships m on m.user_id=p.id
 where p.id=auth.uid() and p.active and r.role='receiver' and m.warehouse_id=w)
$$;
create function wm.can_read_order(oid uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from wm.orders o join wm.profiles p on p.id=auth.uid() and p.active
 where o.id=oid and (o.client_id=auth.uid() or wm.is_operator()
 or (o.driver_id=auth.uid() and wm.is_driver() and o.state not in ('failed','cancelled'))))
$$;
create function wm.require_actor() returns uuid language plpgsql security definer set search_path='' as $$
declare u uuid:=auth.uid();
begin
 if u is null or not exists(select 1 from wm.profiles p join auth.users a on a.id=p.id
 where p.id=u and p.active and (a.email_confirmed_at is not null or a.phone_confirmed_at is not null)) then
 raise exception using message='AUTHENTICATION_REQUIRED',errcode='P0001'; end if;
 return u;
end $$;
create function wm.fail(code text) returns void language plpgsql set search_path='' as $$
begin raise exception using message=code,errcode='P0001'; end $$;
create function wm.point(lat double precision,lng double precision) returns extensions.geometry
 language plpgsql immutable set search_path='' as $$
begin
 if lat is null or lng is null or not(lat between -90 and 90 and lng between -180 and 180) then
 perform wm.fail('INVALID_LOCATION'); end if;
 return extensions.st_setsrid(extensions.st_makepoint(lng,lat),4326);
end $$;
create function wm.emit(oid uuid,kind text,data jsonb default '{}') returns void language plpgsql set search_path='' as $$
begin
 insert into wm.events(order_id,actor_id,kind,data) values(oid,auth.uid(),kind,data);
 insert into wm.outbox(order_id,kind,payload) values(oid,kind,data);
end $$;
create function wm.on_signup() returns trigger language plpgsql security definer set search_path='' as $$
begin
 insert into wm.profiles(id) values(new.id) on conflict do nothing;
 return new;
end $$;
create trigger wm_signup after insert on auth.users for each row execute function wm.on_signup();
insert into wm.profiles(id) select id from auth.users on conflict do nothing;

-- Read policies are defense in depth: wm is not in PostgREST's exposed schemas.
do $$ declare t text; begin
 for t in select tablename from pg_tables where schemaname='wm' loop
 execute format('alter table wm.%I enable row level security',t);
 execute format('revoke all on wm.%I from public, anon, authenticated',t);
 execute format('grant all on wm.%I to service_role',t);
 end loop;
end $$;
grant select on wm.profiles,wm.orders,wm.offers,wm.evidence,wm.incidents to authenticated;
create policy profile_read on wm.profiles for select to authenticated using(id=auth.uid() or wm.is_operator());
create policy order_read on wm.orders for select to authenticated using(wm.can_read_order(id));
create policy offer_read on wm.offers for select to authenticated using((driver_id=auth.uid() and wm.is_driver()) or wm.is_operator());
create policy evidence_read on wm.evidence for select to authenticated using(wm.can_read_order(order_id));
create policy incident_read on wm.incidents for select to authenticated using(reporter_id=auth.uid() or wm.is_operator());
revoke all on all functions in schema wm from public,anon,authenticated;
grant execute on function wm.is_operator(),wm.is_driver(),wm.can_read_order(uuid) to authenticated;
grant all on all sequences in schema wm to service_role;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
 values('wm-evidence','wm-evidence',false,10485760,array['image/jpeg','image/png','image/webp']);
create function wm.can_upload(path text) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from wm.evidence e where e.object_path=path and e.uploader_id=auth.uid()
 and not e.finalized and wm.can_read_order(e.order_id))
$$;
create function wm.can_download(path text) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from wm.evidence e where e.object_path=path and e.finalized and wm.can_read_order(e.order_id))
$$;
revoke all on function wm.can_upload(text),wm.can_download(text) from public;
grant execute on function wm.can_upload(text),wm.can_download(text) to authenticated;
create policy wm_upload on storage.objects for insert to authenticated
 with check(bucket_id='wm-evidence' and wm.can_upload(name));
create policy wm_download on storage.objects for select to authenticated
 using(bucket_id='wm-evidence' and wm.can_download(name));
-- No client update/delete policy: finalized evidence cannot be replaced or erased.
