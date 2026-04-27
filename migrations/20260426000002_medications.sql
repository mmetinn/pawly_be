-- Medications feature
-- Tables: medications, medication_schedules, medication_logs

-- ─────────────────────────────────────────────────────────────
-- medications
-- ─────────────────────────────────────────────────────────────
create table public.medications (
  id             uuid        primary key default uuid_generate_v4(),
  pet_id         uuid        not null references public.pets(id) on delete cascade,
  name           text        not null,
  medication_type text       not null default 'other'
                             check (medication_type in ('pill','liquid','injection','topical','drops','other')),
  dosage         text,
  reason         text,
  prescribed_by  text,
  start_date     date        not null,
  end_date       date,
  is_active      boolean     not null default true,
  notes          text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

alter table public.medications enable row level security;

create policy "medications_select_own" on public.medications
  for select using (
    exists (select 1 from public.pets where pets.id = medications.pet_id and pets.user_id = auth.uid())
  );
create policy "medications_insert_own" on public.medications
  for insert with check (
    exists (select 1 from public.pets where pets.id = medications.pet_id and pets.user_id = auth.uid())
  );
create policy "medications_update_own" on public.medications
  for update using (
    exists (select 1 from public.pets where pets.id = medications.pet_id and pets.user_id = auth.uid())
  );
create policy "medications_delete_own" on public.medications
  for delete using (
    exists (select 1 from public.pets where pets.id = medications.pet_id and pets.user_id = auth.uid())
  );

create index idx_medications_pet_active on public.medications(pet_id, is_active);

-- ─────────────────────────────────────────────────────────────
-- medication_schedules
-- ─────────────────────────────────────────────────────────────
create table public.medication_schedules (
  id               uuid    primary key default uuid_generate_v4(),
  medication_id    uuid    not null references public.medications(id) on delete cascade,
  time_of_day      time    not null,
  days_of_week     int[]   not null default '{1,2,3,4,5,6,7}',
  reminder_enabled boolean not null default true,
  created_at       timestamptz not null default now()
);

alter table public.medication_schedules enable row level security;

create policy "med_schedules_select_own" on public.medication_schedules
  for select using (
    exists (
      select 1 from public.medications m
      join public.pets p on p.id = m.pet_id
      where m.id = medication_schedules.medication_id and p.user_id = auth.uid()
    )
  );
create policy "med_schedules_insert_own" on public.medication_schedules
  for insert with check (
    exists (
      select 1 from public.medications m
      join public.pets p on p.id = m.pet_id
      where m.id = medication_schedules.medication_id and p.user_id = auth.uid()
    )
  );
create policy "med_schedules_update_own" on public.medication_schedules
  for update using (
    exists (
      select 1 from public.medications m
      join public.pets p on p.id = m.pet_id
      where m.id = medication_schedules.medication_id and p.user_id = auth.uid()
    )
  );
create policy "med_schedules_delete_own" on public.medication_schedules
  for delete using (
    exists (
      select 1 from public.medications m
      join public.pets p on p.id = m.pet_id
      where m.id = medication_schedules.medication_id and p.user_id = auth.uid()
    )
  );

create index idx_med_schedules_medication on public.medication_schedules(medication_id);

-- ─────────────────────────────────────────────────────────────
-- medication_logs
-- ─────────────────────────────────────────────────────────────
create table public.medication_logs (
  id            uuid        primary key default uuid_generate_v4(),
  medication_id uuid        not null references public.medications(id) on delete cascade,
  schedule_id   uuid        references public.medication_schedules(id) on delete set null,
  given_at      timestamptz not null default now(),
  status        text        not null default 'given'
                            check (status in ('given','skipped','late')),
  notes         text,
  logged_by     uuid        references auth.users(id) on delete set null,
  created_at    timestamptz not null default now()
);

alter table public.medication_logs enable row level security;

create policy "med_logs_select_own" on public.medication_logs
  for select using (
    exists (
      select 1 from public.medications m
      join public.pets p on p.id = m.pet_id
      where m.id = medication_logs.medication_id and p.user_id = auth.uid()
    )
  );
create policy "med_logs_insert_own" on public.medication_logs
  for insert with check (
    exists (
      select 1 from public.medications m
      join public.pets p on p.id = m.pet_id
      where m.id = medication_logs.medication_id and p.user_id = auth.uid()
    )
  );
create policy "med_logs_delete_own" on public.medication_logs
  for delete using (
    exists (
      select 1 from public.medications m
      join public.pets p on p.id = m.pet_id
      where m.id = medication_logs.medication_id and p.user_id = auth.uid()
    )
  );

create index idx_med_logs_medication_time on public.medication_logs(medication_id, given_at desc);
