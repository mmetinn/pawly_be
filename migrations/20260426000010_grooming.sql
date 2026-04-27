-- Grooming records + coat_type + grooming_preferences on pets

alter table public.pets
  add column if not exists coat_type            text
    check (coat_type in ('short','medium','long','double_coat','hairless','curly')),
  add column if not exists grooming_preferences jsonb;

create table public.grooming_records (
  id               uuid        primary key default uuid_generate_v4(),
  pet_id           uuid        not null references public.pets(id) on delete cascade,
  grooming_type    text        not null default 'other'
                               check (grooming_type in (
                                 'bath','brushing','nail_trim','ear_cleaning',
                                 'teeth_brushing','haircut','anal_gland',
                                 'eye_cleaning','paw_care','flea_bath',
                                 'full_grooming','other'
                               )),
  performed_at     timestamptz not null default now(),
  performed_by     text        not null default 'self'
                               check (performed_by in ('self','groomer','vet','family')),
  location         text,
  product_used     text,
  cost             numeric(10,2),
  currency         text        not null default 'TRY',
  duration_minutes int,
  pet_reaction     text        check (pet_reaction in ('calm','cooperative','anxious','resistant','aggressive')),
  notes            text,
  photo_urls       text[],
  included_services text[],    -- for full_grooming: which sub-services were done
  next_due_date    date,
  reminder_enabled boolean     not null default false,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

alter table public.grooming_records enable row level security;

create policy "grooming_select_own" on public.grooming_records
  for select using (exists (select 1 from public.pets where pets.id = grooming_records.pet_id and pets.user_id = auth.uid()));
create policy "grooming_insert_own" on public.grooming_records
  for insert with check (exists (select 1 from public.pets where pets.id = grooming_records.pet_id and pets.user_id = auth.uid()));
create policy "grooming_update_own" on public.grooming_records
  for update using (exists (select 1 from public.pets where pets.id = grooming_records.pet_id and pets.user_id = auth.uid()));
create policy "grooming_delete_own" on public.grooming_records
  for delete using (exists (select 1 from public.pets where pets.id = grooming_records.pet_id and pets.user_id = auth.uid()));

create index idx_grooming_pet_time on public.grooming_records(pet_id, performed_at desc);
create index idx_grooming_pet_type on public.grooming_records(pet_id, grooming_type, performed_at desc);
