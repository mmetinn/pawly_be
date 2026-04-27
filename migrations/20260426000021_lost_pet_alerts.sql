-- Lost Pet Alerts: kayıp/bulunan pet ilan sistemi
-- Migration: 000021

create type public.alert_status as enum ('active', 'sighted', 'reunited', 'cancelled');
create type public.found_pet_size as enum ('small', 'medium', 'large', 'unknown');
create type public.found_pet_status as enum ('active', 'matched', 'closed');
create type public.pet_species_simple as enum ('dog', 'cat', 'other');

-- ─── lost_pet_alerts ──────────────────────────────────────────────────────────
create table public.lost_pet_alerts (
  id                  uuid primary key default gen_random_uuid(),
  pet_id              uuid references public.pets(id) on delete set null,
  reporter_user_id    uuid not null references auth.users(id) on delete cascade,
  status              public.alert_status not null default 'active',
  last_seen_at        timestamptz not null,
  last_seen_lat       numeric(10,7),
  last_seen_lng       numeric(10,7),
  last_seen_address   text,
  search_radius_km    int not null default 5,
  description         text not null,
  reward_amount       numeric(10,2),
  reward_currency     text not null default 'TRY',
  contact_phone       text not null,
  contact_via_app     boolean not null default true,
  photo_urls          text[] not null default '{}',
  reunited_at         timestamptz,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

-- ─── found_pet_reports ───────────────────────────────────────────────────────
create table public.found_pet_reports (
  id                  uuid primary key default gen_random_uuid(),
  reporter_user_id    uuid not null references auth.users(id) on delete cascade,
  matched_alert_id    uuid references public.lost_pet_alerts(id) on delete set null,
  found_at            timestamptz not null,
  found_lat           numeric(10,7),
  found_lng           numeric(10,7),
  found_address       text,
  species             public.pet_species_simple not null,
  breed_guess         text,
  color               text not null,
  size                public.found_pet_size not null default 'unknown',
  has_collar          boolean,
  has_tag             boolean,
  description         text not null,
  photo_urls          text[] not null default '{}',
  reporter_phone      text,
  status              public.found_pet_status not null default 'active',
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

-- ─── pet_alert_sightings ─────────────────────────────────────────────────────
create table public.pet_alert_sightings (
  id                  uuid primary key default gen_random_uuid(),
  alert_id            uuid not null references public.lost_pet_alerts(id) on delete cascade,
  reporter_user_id    uuid references auth.users(id) on delete set null,
  sighted_at          timestamptz not null default now(),
  sighted_lat         numeric(10,7),
  sighted_lng         numeric(10,7),
  sighted_address     text,
  description         text,
  photo_url           text,
  is_anonymous        boolean not null default false,
  is_verified         boolean not null default false,
  created_at          timestamptz not null default now()
);

-- ─── pet_alert_subscriptions ─────────────────────────────────────────────────
create table public.pet_alert_subscriptions (
  id                    uuid primary key default gen_random_uuid(),
  user_id               uuid not null references auth.users(id) on delete cascade,
  center_lat            numeric(10,7) not null,
  center_lng            numeric(10,7) not null,
  radius_km             int not null default 10,
  notification_enabled  boolean not null default true,
  created_at            timestamptz not null default now(),
  unique(user_id)
);

-- ─── Indexes ─────────────────────────────────────────────────────────────────
create index lost_alerts_status_idx on public.lost_pet_alerts(status, last_seen_at desc);
create index lost_alerts_geo_idx on public.lost_pet_alerts(last_seen_lat, last_seen_lng) where status = 'active';
create index lost_alerts_reporter_idx on public.lost_pet_alerts(reporter_user_id);
create index found_reports_status_idx on public.found_pet_reports(status, found_at desc);
create index sightings_alert_idx on public.pet_alert_sightings(alert_id, created_at desc);
create index subscriptions_user_idx on public.pet_alert_subscriptions(user_id);

-- ─── RLS ─────────────────────────────────────────────────────────────────────
alter table public.lost_pet_alerts enable row level security;
alter table public.found_pet_reports enable row level security;
alter table public.pet_alert_sightings enable row level security;
alter table public.pet_alert_subscriptions enable row level security;

-- Active alerts are public (anon + auth)
create policy "lost_alerts_public_select" on public.lost_pet_alerts
  for select using (status = 'active' or reporter_user_id = auth.uid());

create policy "lost_alerts_insert" on public.lost_pet_alerts
  for insert with check (reporter_user_id = auth.uid());

create policy "lost_alerts_update_own" on public.lost_pet_alerts
  for update using (reporter_user_id = auth.uid());

-- Found reports: public read for active, own CRUD
create policy "found_reports_public_select" on public.found_pet_reports
  for select using (status = 'active' or reporter_user_id = auth.uid());

create policy "found_reports_insert" on public.found_pet_reports
  for insert with check (reporter_user_id = auth.uid());

create policy "found_reports_update_own" on public.found_pet_reports
  for update using (reporter_user_id = auth.uid());

-- Sightings: public read, auth insert, reporter or alert owner can update
create policy "sightings_public_select" on public.pet_alert_sightings
  for select using (true);

create policy "sightings_insert" on public.pet_alert_sightings
  for insert with check (auth.uid() is not null);

create policy "sightings_update" on public.pet_alert_sightings
  for update using (
    reporter_user_id = auth.uid() or
    exists (select 1 from public.lost_pet_alerts la where la.id = pet_alert_sightings.alert_id and la.reporter_user_id = auth.uid())
  );

-- Subscriptions: user owns their own
create policy "subscriptions_own" on public.pet_alert_subscriptions
  for all using (user_id = auth.uid());
