-- Base schema for Pawly
-- Tables: profiles, pets, vaccinations, reminders, vet_favorites, purchases

-- ─────────────────────────────────────────────────────────────
-- Profiles (extends auth.users 1:1)
-- ─────────────────────────────────────────────────────────────
create table public.profiles (
  id                   uuid        primary key references auth.users(id) on delete cascade,
  email                text        not null,
  display_name         text,
  avatar_url           text,
  locale               text        not null default 'tr',
  country              text        not null default 'TR',
  is_premium           boolean     not null default false,
  premium_purchased_at timestamptz,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);

alter table public.profiles enable row level security;

create policy "profiles_select_own" on public.profiles
  for select using (auth.uid() = id);

create policy "profiles_insert_own" on public.profiles
  for insert with check (auth.uid() = id);

create policy "profiles_update_own" on public.profiles
  for update using (auth.uid() = id);

-- Auto-create profile on new user
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer
set search_path = public as $$
begin
  insert into public.profiles (id, email, display_name)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email, '@', 1))
  );
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ─────────────────────────────────────────────────────────────
-- Pets
-- ─────────────────────────────────────────────────────────────
create table public.pets (
  id               uuid        primary key default uuid_generate_v4(),
  user_id          uuid        not null references public.profiles(id) on delete cascade,
  name             text        not null,
  species          text        not null check (species in ('dog','cat')),
  breed            text,
  birth_date       date,
  gender           text        not null default 'unknown' check (gender in ('male','female','unknown')),
  weight_kg        numeric(5,2),
  color            text,
  microchip_number text,
  avatar_url       text,
  notes            text,
  is_neutered      boolean     not null default false,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  deleted_at       timestamptz
);

alter table public.pets enable row level security;

create policy "pets_select_own" on public.pets
  for select using (auth.uid() = user_id);

create policy "pets_insert_own" on public.pets
  for insert with check (auth.uid() = user_id);

create policy "pets_update_own" on public.pets
  for update using (auth.uid() = user_id);

create policy "pets_delete_own" on public.pets
  for delete using (auth.uid() = user_id);

create index idx_pets_user_id on public.pets(user_id) where deleted_at is null;

-- ─────────────────────────────────────────────────────────────
-- Vaccinations
-- ─────────────────────────────────────────────────────────────
create table public.vaccinations (
  id                  uuid        primary key default uuid_generate_v4(),
  pet_id              uuid        not null references public.pets(id) on delete cascade,
  vaccine_name        text        not null,
  vaccine_type        text,
  administered_date   date        not null,
  next_due_date       date,
  veterinarian_name   text,
  clinic_name         text,
  batch_number        text,
  notes               text,
  reminder_enabled    boolean     not null default false,
  reminder_lead_days  integer     not null default 7,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

alter table public.vaccinations enable row level security;

create policy "vaccinations_select_own" on public.vaccinations
  for select using (
    exists (select 1 from public.pets where pets.id = vaccinations.pet_id and pets.user_id = auth.uid())
  );

create policy "vaccinations_insert_own" on public.vaccinations
  for insert with check (
    exists (select 1 from public.pets where pets.id = vaccinations.pet_id and pets.user_id = auth.uid())
  );

create policy "vaccinations_update_own" on public.vaccinations
  for update using (
    exists (select 1 from public.pets where pets.id = vaccinations.pet_id and pets.user_id = auth.uid())
  );

create policy "vaccinations_delete_own" on public.vaccinations
  for delete using (
    exists (select 1 from public.pets where pets.id = vaccinations.pet_id and pets.user_id = auth.uid())
  );

create index idx_vaccinations_pet_id on public.vaccinations(pet_id);

-- ─────────────────────────────────────────────────────────────
-- Reminders
-- ─────────────────────────────────────────────────────────────
create table public.reminders (
  id               uuid        primary key default uuid_generate_v4(),
  pet_id           uuid        not null references public.pets(id) on delete cascade,
  type             text        not null check (type in ('food','medication','vaccination','grooming','vet_visit','custom')),
  title            text        not null,
  description      text,
  scheduled_at     timestamptz not null,
  recurrence_rule  text,
  is_completed     boolean     not null default false,
  completed_at     timestamptz,
  notification_id  text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

alter table public.reminders enable row level security;

create policy "reminders_select_own" on public.reminders
  for select using (
    exists (select 1 from public.pets where pets.id = reminders.pet_id and pets.user_id = auth.uid())
  );

create policy "reminders_insert_own" on public.reminders
  for insert with check (
    exists (select 1 from public.pets where pets.id = reminders.pet_id and pets.user_id = auth.uid())
  );

create policy "reminders_update_own" on public.reminders
  for update using (
    exists (select 1 from public.pets where pets.id = reminders.pet_id and pets.user_id = auth.uid())
  );

create policy "reminders_delete_own" on public.reminders
  for delete using (
    exists (select 1 from public.pets where pets.id = reminders.pet_id and pets.user_id = auth.uid())
  );

create index idx_reminders_pet_id on public.reminders(pet_id);
create index idx_reminders_scheduled_at on public.reminders(scheduled_at) where is_completed = false;

-- ─────────────────────────────────────────────────────────────
-- Vet Favorites
-- ─────────────────────────────────────────────────────────────
create table public.vet_favorites (
  id               uuid        primary key default uuid_generate_v4(),
  user_id          uuid        not null references public.profiles(id) on delete cascade,
  google_place_id  text        not null,
  name             text        not null,
  address          text,
  latitude         double precision,
  longitude        double precision,
  phone            text,
  rating           numeric(3,1),
  notes            text,
  created_at       timestamptz not null default now(),
  unique(user_id, google_place_id)
);

alter table public.vet_favorites enable row level security;

create policy "vet_favorites_select_own" on public.vet_favorites
  for select using (auth.uid() = user_id);

create policy "vet_favorites_insert_own" on public.vet_favorites
  for insert with check (auth.uid() = user_id);

create policy "vet_favorites_delete_own" on public.vet_favorites
  for delete using (auth.uid() = user_id);

create index idx_vet_favorites_user_id on public.vet_favorites(user_id);

-- ─────────────────────────────────────────────────────────────
-- Purchases (audit log — written only by Edge Function)
-- ─────────────────────────────────────────────────────────────
create table public.purchases (
  id             uuid        primary key default uuid_generate_v4(),
  user_id        uuid        not null references public.profiles(id) on delete cascade,
  product_id     text        not null,
  platform       text        not null check (platform in ('ios','android')),
  transaction_id text        not null,
  purchased_at   timestamptz not null,
  expires_at     timestamptz,
  raw_payload    jsonb,
  created_at     timestamptz not null default now(),
  unique(platform, transaction_id)
);

alter table public.purchases enable row level security;

-- Clients can only read their own purchase records
create policy "purchases_select_own" on public.purchases
  for select using (auth.uid() = user_id);

-- No client INSERT/UPDATE/DELETE — Edge Function uses service role key

create index idx_purchases_user_id on public.purchases(user_id);

-- ─────────────────────────────────────────────────────────────
-- Storage: pet-avatars bucket
-- ─────────────────────────────────────────────────────────────
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'pet-avatars',
  'pet-avatars',
  true,
  5242880,  -- 5 MB
  array['image/jpeg','image/png','image/webp']
)
on conflict (id) do nothing;

create policy "avatars_select_public" on storage.objects
  for select using (bucket_id = 'pet-avatars');

create policy "avatars_insert_own" on storage.objects
  for insert with check (
    bucket_id = 'pet-avatars' and
    auth.uid()::text = (storage.foldername(name))[1]
  );

create policy "avatars_update_own" on storage.objects
  for update using (
    bucket_id = 'pet-avatars' and
    auth.uid()::text = (storage.foldername(name))[1]
  );

create policy "avatars_delete_own" on storage.objects
  for delete using (
    bucket_id = 'pet-avatars' and
    auth.uid()::text = (storage.foldername(name))[1]
  );
