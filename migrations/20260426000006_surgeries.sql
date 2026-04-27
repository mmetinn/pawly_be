-- Surgery records + recovery logs + attachments
-- pets table: add coat_type (for grooming, referenced here for completeness)

create table public.surgeries (
  id                          uuid        primary key default uuid_generate_v4(),
  pet_id                      uuid        not null references public.pets(id) on delete cascade,
  vet_visit_id                uuid        references public.vet_visits(id) on delete set null,
  surgery_type                text        not null default 'other'
                                          check (surgery_type in (
                                            'spay','neuter','dental','mass_removal',
                                            'orthopedic','soft_tissue','eye','cesarean',
                                            'cherry_eye','cryptorchid','foreign_body',
                                            'biopsy','other'
                                          )),
  surgery_name                text,
  surgery_date                date        not null,
  surgeon_name                text,
  clinic_name                 text,
  clinic_place_id             text,
  anesthesia_type             text        check (anesthesia_type in ('general','local','sedation','none','unknown')),
  duration_minutes            int,
  cost                        numeric(10,2),
  currency                    text        not null default 'TRY',
  reason                      text,
  procedure_notes             text,
  sutures_type                text        check (sutures_type in ('absorbable','non_absorbable','staples','glue','none')),
  suture_removal_date         date,
  suture_removed              boolean     not null default false,
  cone_required               boolean     not null default false,
  cone_until_date             date,
  activity_restriction_until  date,
  recovery_status             text        not null default 'pre_op'
                                          check (recovery_status in ('pre_op','recovering','completed','complicated')),
  complications               text,
  histopathology_result       text,
  notes                       text,
  created_at                  timestamptz not null default now(),
  updated_at                  timestamptz not null default now()
);

alter table public.surgeries enable row level security;

create policy "surgeries_select_own" on public.surgeries
  for select using (exists (select 1 from public.pets where pets.id = surgeries.pet_id and pets.user_id = auth.uid()));
create policy "surgeries_insert_own" on public.surgeries
  for insert with check (exists (select 1 from public.pets where pets.id = surgeries.pet_id and pets.user_id = auth.uid()));
create policy "surgeries_update_own" on public.surgeries
  for update using (exists (select 1 from public.pets where pets.id = surgeries.pet_id and pets.user_id = auth.uid()));
create policy "surgeries_delete_own" on public.surgeries
  for delete using (exists (select 1 from public.pets where pets.id = surgeries.pet_id and pets.user_id = auth.uid()));

create index idx_surgeries_pet_date   on public.surgeries(pet_id, surgery_date desc);
create index idx_surgeries_recovery   on public.surgeries(recovery_status);

-- ── Surgery attachments ────────────────────────────────────────────────────────

create table public.surgery_attachments (
  id          uuid        primary key default uuid_generate_v4(),
  surgery_id  uuid        not null references public.surgeries(id) on delete cascade,
  file_url    text        not null,
  file_type   text        not null default 'image' check (file_type in ('image','pdf','video')),
  file_category text      not null default 'other'
                          check (file_category in ('before','after','recovery_progress','document','other')),
  taken_at    timestamptz,
  description text,
  uploaded_at timestamptz not null default now()
);

alter table public.surgery_attachments enable row level security;

create policy "surgery_attachments_select_own" on public.surgery_attachments
  for select using (exists (
    select 1 from public.surgeries s join public.pets p on p.id = s.pet_id
    where s.id = surgery_attachments.surgery_id and p.user_id = auth.uid()
  ));
create policy "surgery_attachments_insert_own" on public.surgery_attachments
  for insert with check (exists (
    select 1 from public.surgeries s join public.pets p on p.id = s.pet_id
    where s.id = surgery_attachments.surgery_id and p.user_id = auth.uid()
  ));
create policy "surgery_attachments_delete_own" on public.surgery_attachments
  for delete using (exists (
    select 1 from public.surgeries s join public.pets p on p.id = s.pet_id
    where s.id = surgery_attachments.surgery_id and p.user_id = auth.uid()
  ));

create index idx_surgery_attachments_surgery on public.surgery_attachments(surgery_id);

-- ── Surgery recovery logs ─────────────────────────────────────────────────────

create table public.surgery_recovery_logs (
  id               uuid        primary key default uuid_generate_v4(),
  surgery_id       uuid        not null references public.surgeries(id) on delete cascade,
  logged_date      date        not null,
  appetite         text        check (appetite in ('normal','reduced','none')),
  energy_level     text        check (energy_level in ('normal','low','very_low')),
  wound_appearance text        check (wound_appearance in ('healing_well','red_swollen','discharge','concerning')),
  pain_level       int         check (pain_level between 1 and 10),
  notes            text,
  photo_url        text,
  created_at       timestamptz not null default now()
);

alter table public.surgery_recovery_logs enable row level security;

create policy "surgery_logs_select_own" on public.surgery_recovery_logs
  for select using (exists (
    select 1 from public.surgeries s join public.pets p on p.id = s.pet_id
    where s.id = surgery_recovery_logs.surgery_id and p.user_id = auth.uid()
  ));
create policy "surgery_logs_insert_own" on public.surgery_recovery_logs
  for insert with check (exists (
    select 1 from public.surgeries s join public.pets p on p.id = s.pet_id
    where s.id = surgery_recovery_logs.surgery_id and p.user_id = auth.uid()
  ));
create policy "surgery_logs_delete_own" on public.surgery_recovery_logs
  for delete using (exists (
    select 1 from public.surgeries s join public.pets p on p.id = s.pet_id
    where s.id = surgery_recovery_logs.surgery_id and p.user_id = auth.uid()
  ));

create index idx_surgery_logs_surgery_date on public.surgery_recovery_logs(surgery_id, logged_date desc);
