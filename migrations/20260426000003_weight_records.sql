-- Weight tracking
-- Adds weight_records table + target_weight_kg / target_date to pets

alter table public.pets
  add column if not exists target_weight_kg numeric(5,2),
  add column if not exists target_date       date;

create table public.weight_records (
  id                    uuid        primary key default uuid_generate_v4(),
  pet_id                uuid        not null references public.pets(id) on delete cascade,
  weight_kg             numeric(5,2) not null check (weight_kg > 0),
  measured_at           timestamptz  not null default now(),
  body_condition_score  int          check (body_condition_score between 1 and 9),
  notes                 text,
  measured_by           uuid         references auth.users(id) on delete set null,
  created_at            timestamptz  not null default now()
);

alter table public.weight_records enable row level security;

create policy "weight_records_select_own" on public.weight_records
  for select using (
    exists (select 1 from public.pets where pets.id = weight_records.pet_id and pets.user_id = auth.uid())
  );
create policy "weight_records_insert_own" on public.weight_records
  for insert with check (
    exists (select 1 from public.pets where pets.id = weight_records.pet_id and pets.user_id = auth.uid())
  );
create policy "weight_records_update_own" on public.weight_records
  for update using (
    exists (select 1 from public.pets where pets.id = weight_records.pet_id and pets.user_id = auth.uid())
  );
create policy "weight_records_delete_own" on public.weight_records
  for delete using (
    exists (select 1 from public.pets where pets.id = weight_records.pet_id and pets.user_id = auth.uid())
  );

create index idx_weight_records_pet_time on public.weight_records(pet_id, measured_at desc);
