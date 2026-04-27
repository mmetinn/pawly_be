-- Migration: vet map / clinic finder
-- Extends vet_favorites, adds vet_search_history, adds clinic_place_id index

-- 1. Extend vet_favorites with new columns
alter table public.vet_favorites
  add column if not exists is_primary       boolean     not null default false,
  add column if not exists website          text,
  add column if not exists tags             text[]      default '{}',
  add column if not exists last_visit_date  date,
  add column if not exists updated_at       timestamptz not null default now();

-- Rename notes -> personal_notes for clarity (keep notes as alias via view if needed)
-- Just add personal_notes; notes stays for backwards compat
alter table public.vet_favorites
  add column if not exists personal_notes text;

-- Partial unique index: only 1 primary vet per user
create unique index if not exists idx_vet_favorites_one_primary
  on public.vet_favorites(user_id)
  where is_primary = true;

-- Update policy to include update
create policy "vet_favorites_update_own" on public.vet_favorites
  for update using (auth.uid() = user_id);

-- 2. vet_search_history
create table if not exists public.vet_search_history (
  id           uuid        primary key default uuid_generate_v4(),
  user_id      uuid        not null references public.profiles(id) on delete cascade,
  place_id     text        not null,
  clinic_name  text,
  searched_at  timestamptz not null default now(),
  viewed_count int         not null default 1
);

alter table public.vet_search_history enable row level security;

create policy "vet_search_history_select_own" on public.vet_search_history
  for select using (auth.uid() = user_id);

create policy "vet_search_history_insert_own" on public.vet_search_history
  for insert with check (auth.uid() = user_id);

create policy "vet_search_history_update_own" on public.vet_search_history
  for update using (auth.uid() = user_id);

create policy "vet_search_history_delete_own" on public.vet_search_history
  for delete using (auth.uid() = user_id);

create index if not exists idx_vet_search_history_user_searched
  on public.vet_search_history(user_id, searched_at desc);

create unique index if not exists idx_vet_search_history_user_place
  on public.vet_search_history(user_id, place_id);

-- 3. vet_visits already has clinic_place_id; add index if not exists
create index if not exists idx_vet_visits_clinic_place_id
  on public.vet_visits(clinic_place_id)
  where clinic_place_id is not null;
