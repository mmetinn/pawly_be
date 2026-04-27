-- Parasite treatments + region on profiles

alter table public.profiles
  add column if not exists region text
    check (region in ('mediterranean','aegean','marmara','blackSea',
                      'centralAnatolia','easternAnatolia','southeasternAnatolia'));

create table public.parasite_treatments (
  id                       uuid        primary key default uuid_generate_v4(),
  pet_id                   uuid        not null references public.pets(id) on delete cascade,
  treatment_category       text        not null default 'external'
                                       check (treatment_category in ('external','internal','combined')),
  product_name             text        not null,
  active_ingredient        text,
  administration_form      text        not null default 'spot_on'
                                       check (administration_form in (
                                         'spot_on','oral_tablet','collar','spray',
                                         'injection','shampoo'
                                       )),
  administered_date        date        not null,
  protection_duration_days int         not null check (protection_duration_days > 0),
  next_due_date            date        not null,
  target_parasites         text[],
  weight_at_treatment_kg   numeric(5,2),
  cost                     numeric(10,2),
  currency                 text        not null default 'TRY',
  notes                    text,
  reminder_enabled         boolean     not null default true,
  reminder_days_before     int         not null default 7,
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now()
);

alter table public.parasite_treatments enable row level security;

create policy "parasite_select_own" on public.parasite_treatments
  for select using (exists (select 1 from public.pets where pets.id = parasite_treatments.pet_id and pets.user_id = auth.uid()));
create policy "parasite_insert_own" on public.parasite_treatments
  for insert with check (exists (select 1 from public.pets where pets.id = parasite_treatments.pet_id and pets.user_id = auth.uid()));
create policy "parasite_update_own" on public.parasite_treatments
  for update using (exists (select 1 from public.pets where pets.id = parasite_treatments.pet_id and pets.user_id = auth.uid()));
create policy "parasite_delete_own" on public.parasite_treatments
  for delete using (exists (select 1 from public.pets where pets.id = parasite_treatments.pet_id and pets.user_id = auth.uid()));

create index idx_parasite_pet_due  on public.parasite_treatments(pet_id, next_due_date);
create index idx_parasite_pet_cat  on public.parasite_treatments(pet_id, treatment_category);
