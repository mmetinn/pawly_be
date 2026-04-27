-- Vet visits + attachments + lab results
-- Storage bucket: vet-attachments (private)

create table public.vet_visits (
  id                   uuid        primary key default uuid_generate_v4(),
  pet_id               uuid        not null references public.pets(id) on delete cascade,
  visit_date           date        not null,
  visit_type           text        not null default 'routine_checkup'
                                   check (visit_type in (
                                     'routine_checkup','illness','injury','surgery',
                                     'dental','emergency','follow_up','lab_work',
                                     'imaging','other'
                                   )),
  veterinarian_name    text,
  clinic_name          text,
  clinic_place_id      text,
  chief_complaint      text,
  diagnosis            text,
  treatment            text,
  cost                 numeric(10,2),
  currency             text        not null default 'TRY',
  follow_up_required   boolean     not null default false,
  follow_up_date       date,
  notes                text,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);

alter table public.vet_visits enable row level security;

create policy "vet_visits_select_own" on public.vet_visits
  for select using (exists (select 1 from public.pets where pets.id = vet_visits.pet_id and pets.user_id = auth.uid()));
create policy "vet_visits_insert_own" on public.vet_visits
  for insert with check (exists (select 1 from public.pets where pets.id = vet_visits.pet_id and pets.user_id = auth.uid()));
create policy "vet_visits_update_own" on public.vet_visits
  for update using (exists (select 1 from public.pets where pets.id = vet_visits.pet_id and pets.user_id = auth.uid()));
create policy "vet_visits_delete_own" on public.vet_visits
  for delete using (exists (select 1 from public.pets where pets.id = vet_visits.pet_id and pets.user_id = auth.uid()));

create index idx_vet_visits_pet_date on public.vet_visits(pet_id, visit_date desc);

-- ── Attachments ────────────────────────────────────────────────────────────────

create table public.vet_visit_attachments (
  id               uuid        primary key default uuid_generate_v4(),
  visit_id         uuid        not null references public.vet_visits(id) on delete cascade,
  file_url         text        not null,
  file_type        text        not null default 'image' check (file_type in ('image','pdf','other')),
  file_name        text,
  file_size_bytes  bigint,
  description      text,
  uploaded_at      timestamptz not null default now()
);

alter table public.vet_visit_attachments enable row level security;

create policy "vet_attachments_select_own" on public.vet_visit_attachments
  for select using (exists (
    select 1 from public.vet_visits v join public.pets p on p.id = v.pet_id
    where v.id = vet_visit_attachments.visit_id and p.user_id = auth.uid()
  ));
create policy "vet_attachments_insert_own" on public.vet_visit_attachments
  for insert with check (exists (
    select 1 from public.vet_visits v join public.pets p on p.id = v.pet_id
    where v.id = vet_visit_attachments.visit_id and p.user_id = auth.uid()
  ));
create policy "vet_attachments_delete_own" on public.vet_visit_attachments
  for delete using (exists (
    select 1 from public.vet_visits v join public.pets p on p.id = v.pet_id
    where v.id = vet_visit_attachments.visit_id and p.user_id = auth.uid()
  ));

create index idx_vet_attachments_visit on public.vet_visit_attachments(visit_id);

-- ── Lab results ────────────────────────────────────────────────────────────────

create table public.vet_visit_lab_results (
  id               uuid    primary key default uuid_generate_v4(),
  visit_id         uuid    not null references public.vet_visits(id) on delete cascade,
  test_name        text    not null,
  value            text    not null,
  unit             text,
  reference_range  text,
  is_abnormal      boolean not null default false,
  created_at       timestamptz not null default now()
);

alter table public.vet_visit_lab_results enable row level security;

create policy "lab_results_select_own" on public.vet_visit_lab_results
  for select using (exists (
    select 1 from public.vet_visits v join public.pets p on p.id = v.pet_id
    where v.id = vet_visit_lab_results.visit_id and p.user_id = auth.uid()
  ));
create policy "lab_results_insert_own" on public.vet_visit_lab_results
  for insert with check (exists (
    select 1 from public.vet_visits v join public.pets p on p.id = v.pet_id
    where v.id = vet_visit_lab_results.visit_id and p.user_id = auth.uid()
  ));
create policy "lab_results_update_own" on public.vet_visit_lab_results
  for update using (exists (
    select 1 from public.vet_visits v join public.pets p on p.id = v.pet_id
    where v.id = vet_visit_lab_results.visit_id and p.user_id = auth.uid()
  ));
create policy "lab_results_delete_own" on public.vet_visit_lab_results
  for delete using (exists (
    select 1 from public.vet_visits v join public.pets p on p.id = v.pet_id
    where v.id = vet_visit_lab_results.visit_id and p.user_id = auth.uid()
  ));

create index idx_lab_results_visit on public.vet_visit_lab_results(visit_id);

-- ── Storage bucket (private, 10 MB max) ──────────────────────────────────────
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'vet-attachments', 'vet-attachments', false,
  10485760,
  array['image/jpeg','image/png','image/webp','image/heic','application/pdf']
)
on conflict (id) do nothing;

create policy "vet_attachments_storage_select" on storage.objects
  for select using (
    bucket_id = 'vet-attachments' and auth.uid()::text = (storage.foldername(name))[1]
  );
create policy "vet_attachments_storage_insert" on storage.objects
  for insert with check (
    bucket_id = 'vet-attachments' and auth.uid()::text = (storage.foldername(name))[1]
  );
create policy "vet_attachments_storage_delete" on storage.objects
  for delete using (
    bucket_id = 'vet-attachments' and auth.uid()::text = (storage.foldername(name))[1]
  );
