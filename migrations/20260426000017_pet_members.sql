-- Migration: pet_members (multi-user family access)
-- CRITICAL architectural change: pet access goes from 1:1 (pet.user_id) to M:N (pet_members)
-- Existing pets migrated to owner role for backward compatibility.
-- Pro+ feature (5 members/pet), Premium (1 member), Free (none).

-- ─── pet_members (create table FIRST so helper functions can reference it) ────

create table public.pet_members (
  id                        uuid        primary key default uuid_generate_v4(),
  pet_id                    uuid        not null references public.pets(id) on delete cascade,
  user_id                   uuid        not null references auth.users(id) on delete cascade,
  role                      text        not null default 'viewer'
                              check (role in ('owner','co_owner','caregiver','sitter','viewer')),
  permissions               jsonb       not null default '{
    "view_records": true,
    "add_logs": false,
    "edit_pet_info": false,
    "delete_records": false,
    "manage_members": false,
    "view_costs": false
  }',
  access_expires_at         timestamptz,
  invited_by                uuid        references auth.users(id) on delete set null,
  invited_at                timestamptz not null default now(),
  accepted_at               timestamptz,
  status                    text        not null default 'pending'
                              check (status in ('pending','active','revoked','expired')),
  notification_preferences  jsonb       not null default '{
    "feeding_reminders": false,
    "medication_alerts": false,
    "emergency_only": true
  }',
  created_at                timestamptz not null default now(),
  updated_at                timestamptz not null default now(),
  unique(pet_id, user_id)
);

alter table public.pet_members enable row level security;

-- pet_members RLS uses direct subqueries (avoids circular function dependency)
create policy "pet_members_select" on public.pet_members
  for select using (
    exists (
      select 1 from public.pet_members pm0
      where pm0.pet_id = pet_members.pet_id
        and pm0.user_id = auth.uid()
        and pm0.status = 'active'
    )
  );

-- Only owners/co-owners can insert new members
create policy "pet_members_insert_owner" on public.pet_members
  for insert with check (
    auth.uid() = invited_by
    and exists (
      select 1 from public.pet_members pm
      where pm.pet_id = pet_members.pet_id
        and pm.user_id = auth.uid()
        and pm.role in ('owner','co_owner')
        and pm.status = 'active'
    )
  );

-- Owners can update; users can update their own record (accept invitation)
create policy "pet_members_update" on public.pet_members
  for update using (
    auth.uid() = user_id
    or exists (
      select 1 from public.pet_members pm2
      where pm2.pet_id = pet_members.pet_id
        and pm2.user_id = auth.uid()
        and pm2.role in ('owner','co_owner')
        and pm2.status = 'active'
    )
  );

-- Owners can delete; users can remove themselves
create policy "pet_members_delete" on public.pet_members
  for delete using (
    auth.uid() = user_id
    or exists (
      select 1 from public.pet_members pm_del
      where pm_del.pet_id = pet_members.pet_id
        and pm_del.user_id = auth.uid()
        and pm_del.role = 'owner'
        and pm_del.status = 'active'
    )
  );

create index idx_pet_members_pet   on public.pet_members(pet_id, status);
create index idx_pet_members_user  on public.pet_members(user_id, status);

-- ─── Helper functions (after pet_members table exists) ───────────────────────

create or replace function public.is_pet_member(p_pet_id uuid, p_user_id uuid)
returns boolean
language sql
security definer
stable
as $$
  select exists (
    select 1 from public.pet_members
    where pet_id = p_pet_id
      and user_id = p_user_id
      and status = 'active'
      and (access_expires_at is null or access_expires_at > now())
  );
$$;

create or replace function public.is_pet_owner(p_pet_id uuid, p_user_id uuid)
returns boolean
language sql
security definer
stable
as $$
  select exists (
    select 1 from public.pet_members
    where pet_id = p_pet_id
      and user_id = p_user_id
      and role = 'owner'
      and status = 'active'
  );
$$;

-- ─── pet_invitations ─────────────────────────────────────────────────────────

create table public.pet_invitations (
  id                uuid        primary key default uuid_generate_v4(),
  pet_id            uuid        not null references public.pets(id) on delete cascade,
  inviter_id        uuid        not null references auth.users(id) on delete cascade,
  invitee_email     text,
  invitee_phone     text,
  role              text        not null default 'caregiver'
                      check (role in ('co_owner','caregiver','sitter','viewer')),
  permissions       jsonb,
  access_expires_at timestamptz,
  invitation_code   text        not null unique,
  status            text        not null default 'pending'
                      check (status in ('pending','accepted','rejected','expired')),
  sent_at           timestamptz not null default now(),
  accepted_at       timestamptz,
  created_at        timestamptz not null default now()
);

alter table public.pet_invitations enable row level security;

create policy "pet_invitations_select" on public.pet_invitations
  for select using (
    auth.uid() = inviter_id
    or invitee_email = (select email from public.profiles where id = auth.uid())
  );

create policy "pet_invitations_insert" on public.pet_invitations
  for insert with check (
    auth.uid() = inviter_id
    and public.is_pet_member(pet_id, auth.uid())
  );

create policy "pet_invitations_update" on public.pet_invitations
  for update using (
    auth.uid() = inviter_id
    or invitee_email = (select email from public.profiles where id = auth.uid())
  );

create index idx_pet_invitations_code   on public.pet_invitations(invitation_code, status);
create index idx_pet_invitations_email  on public.pet_invitations(invitee_email, status);
create index idx_pet_invitations_pet    on public.pet_invitations(pet_id);

-- ─── audit_log ───────────────────────────────────────────────────────────────

create table public.pet_audit_log (
  id          uuid        primary key default uuid_generate_v4(),
  pet_id      uuid        not null references public.pets(id) on delete cascade,
  actor_id    uuid        references auth.users(id) on delete set null,
  action      text        not null,
  details     jsonb,
  created_at  timestamptz not null default now()
);

alter table public.pet_audit_log enable row level security;

create policy "pet_audit_log_select" on public.pet_audit_log
  for select using (public.is_pet_member(pet_id, auth.uid()));

create policy "pet_audit_log_insert" on public.pet_audit_log
  for insert with check (auth.uid() = actor_id);

create index idx_pet_audit_log_pet_date on public.pet_audit_log(pet_id, created_at desc);

-- ─── Step 2: Migrate existing pets to owner role ──────────────────────────────

insert into public.pet_members (pet_id, user_id, role, status, accepted_at, invited_at,
  permissions, notification_preferences)
select
  id as pet_id,
  user_id,
  'owner' as role,
  'active' as status,
  created_at as accepted_at,
  created_at as invited_at,
  '{
    "view_records": true,
    "add_logs": true,
    "edit_pet_info": true,
    "delete_records": true,
    "manage_members": true,
    "view_costs": true
  }'::jsonb as permissions,
  '{
    "feeding_reminders": true,
    "medication_alerts": true,
    "emergency_only": false
  }'::jsonb as notification_preferences
from public.pets
on conflict (pet_id, user_id) do nothing;

-- ─── Step 3: Add owner_id to pets (copy from user_id) ────────────────────────

alter table public.pets add column if not exists owner_id uuid references auth.users(id) on delete set null;
update public.pets set owner_id = user_id where owner_id is null;

-- ─── Step 4: Update pets RLS to use pet_members ──────────────────────────────

-- Drop old pet policies and recreate using pet_members
drop policy if exists "pets_select_own" on public.pets;
drop policy if exists "pets_insert_own" on public.pets;
drop policy if exists "pets_update_own" on public.pets;
drop policy if exists "pets_delete_own" on public.pets;

create policy "pets_select_member" on public.pets
  for select using (public.is_pet_member(id, auth.uid()));

create policy "pets_insert_own" on public.pets
  for insert to authenticated with check (auth.uid() = user_id);

create policy "pets_update_member" on public.pets
  for update using (public.is_pet_member(id, auth.uid()));

create policy "pets_delete_owner" on public.pets
  for delete using (public.is_pet_owner(id, auth.uid()));

-- ─── Step 5: Update pet-related table RLS to use pet_members ────────────────
-- Pattern: replace "pets.user_id = auth.uid()" with "is_pet_member(pet_id, auth.uid())"

-- vaccinations
drop policy if exists "vaccinations_select_own" on public.vaccinations;
drop policy if exists "vaccinations_insert_own" on public.vaccinations;
drop policy if exists "vaccinations_update_own" on public.vaccinations;
drop policy if exists "vaccinations_delete_own" on public.vaccinations;

create policy "vaccinations_select_member" on public.vaccinations
  for select using (public.is_pet_member(pet_id, auth.uid()));
create policy "vaccinations_insert_member" on public.vaccinations
  for insert with check (public.is_pet_member(pet_id, auth.uid()));
create policy "vaccinations_update_member" on public.vaccinations
  for update using (public.is_pet_member(pet_id, auth.uid()));
create policy "vaccinations_delete_member" on public.vaccinations
  for delete using (public.is_pet_member(pet_id, auth.uid()));

-- reminders
drop policy if exists "reminders_select_own" on public.reminders;
drop policy if exists "reminders_insert_own" on public.reminders;
drop policy if exists "reminders_update_own" on public.reminders;
drop policy if exists "reminders_delete_own" on public.reminders;

create policy "reminders_select_member" on public.reminders
  for select using (public.is_pet_member(pet_id, auth.uid()));
create policy "reminders_insert_member" on public.reminders
  for insert with check (public.is_pet_member(pet_id, auth.uid()));
create policy "reminders_update_member" on public.reminders
  for update using (public.is_pet_member(pet_id, auth.uid()));
create policy "reminders_delete_member" on public.reminders
  for delete using (public.is_pet_member(pet_id, auth.uid()));

-- medications
drop policy if exists "medications_select_own" on public.medications;
drop policy if exists "medications_insert_own" on public.medications;
drop policy if exists "medications_update_own" on public.medications;
drop policy if exists "medications_delete_own" on public.medications;

create policy "medications_select_member" on public.medications
  for select using (public.is_pet_member(pet_id, auth.uid()));
create policy "medications_insert_member" on public.medications
  for insert with check (public.is_pet_member(pet_id, auth.uid()));
create policy "medications_update_member" on public.medications
  for update using (public.is_pet_member(pet_id, auth.uid()));
create policy "medications_delete_member" on public.medications
  for delete using (public.is_pet_member(pet_id, auth.uid()));

-- medication_logs
drop policy if exists "med_logs_select_own" on public.medication_logs;
drop policy if exists "med_logs_insert_own" on public.medication_logs;
drop policy if exists "med_logs_update_own" on public.medication_logs;

create policy "med_logs_select_member" on public.medication_logs
  for select using (
    exists (select 1 from public.medications m where m.id = medication_id and public.is_pet_member(m.pet_id, auth.uid()))
  );
create policy "med_logs_insert_member" on public.medication_logs
  for insert with check (
    exists (select 1 from public.medications m where m.id = medication_id and public.is_pet_member(m.pet_id, auth.uid()))
  );
create policy "med_logs_update_member" on public.medication_logs
  for update using (
    exists (select 1 from public.medications m where m.id = medication_id and public.is_pet_member(m.pet_id, auth.uid()))
  );

-- weight_records
drop policy if exists "weight_records_select_own" on public.weight_records;
drop policy if exists "weight_records_insert_own" on public.weight_records;
drop policy if exists "weight_records_update_own" on public.weight_records;
drop policy if exists "weight_records_delete_own" on public.weight_records;

create policy "weight_records_select_member" on public.weight_records
  for select using (public.is_pet_member(pet_id, auth.uid()));
create policy "weight_records_insert_member" on public.weight_records
  for insert with check (public.is_pet_member(pet_id, auth.uid()));
create policy "weight_records_update_member" on public.weight_records
  for update using (public.is_pet_member(pet_id, auth.uid()));
create policy "weight_records_delete_member" on public.weight_records
  for delete using (public.is_pet_member(pet_id, auth.uid()));

-- vet_visits
drop policy if exists "vet_visits_select_own" on public.vet_visits;
drop policy if exists "vet_visits_insert_own" on public.vet_visits;
drop policy if exists "vet_visits_update_own" on public.vet_visits;
drop policy if exists "vet_visits_delete_own" on public.vet_visits;

create policy "vet_visits_select_member" on public.vet_visits
  for select using (public.is_pet_member(pet_id, auth.uid()));
create policy "vet_visits_insert_member" on public.vet_visits
  for insert with check (public.is_pet_member(pet_id, auth.uid()));
create policy "vet_visits_update_member" on public.vet_visits
  for update using (public.is_pet_member(pet_id, auth.uid()));
create policy "vet_visits_delete_member" on public.vet_visits
  for delete using (public.is_pet_member(pet_id, auth.uid()));

-- parasite_treatments
drop policy if exists "parasite_select_own" on public.parasite_treatments;
drop policy if exists "parasite_insert_own" on public.parasite_treatments;
drop policy if exists "parasite_update_own" on public.parasite_treatments;
drop policy if exists "parasite_delete_own" on public.parasite_treatments;

create policy "parasite_select_member" on public.parasite_treatments
  for select using (public.is_pet_member(pet_id, auth.uid()));
create policy "parasite_insert_member" on public.parasite_treatments
  for insert with check (public.is_pet_member(pet_id, auth.uid()));
create policy "parasite_update_member" on public.parasite_treatments
  for update using (public.is_pet_member(pet_id, auth.uid()));
create policy "parasite_delete_member" on public.parasite_treatments
  for delete using (public.is_pet_member(pet_id, auth.uid()));

-- surgeries
drop policy if exists "surgeries_select_own" on public.surgeries;
drop policy if exists "surgeries_insert_own" on public.surgeries;
drop policy if exists "surgeries_update_own" on public.surgeries;
drop policy if exists "surgeries_delete_own" on public.surgeries;

create policy "surgeries_select_member" on public.surgeries
  for select using (public.is_pet_member(pet_id, auth.uid()));
create policy "surgeries_insert_member" on public.surgeries
  for insert with check (public.is_pet_member(pet_id, auth.uid()));
create policy "surgeries_update_member" on public.surgeries
  for update using (public.is_pet_member(pet_id, auth.uid()));
create policy "surgeries_delete_member" on public.surgeries
  for delete using (public.is_pet_member(pet_id, auth.uid()));

-- grooming_records
drop policy if exists "grooming_select_own" on public.grooming_records;
drop policy if exists "grooming_insert_own" on public.grooming_records;
drop policy if exists "grooming_update_own" on public.grooming_records;
drop policy if exists "grooming_delete_own" on public.grooming_records;

create policy "grooming_select_member" on public.grooming_records
  for select using (public.is_pet_member(pet_id, auth.uid()));
create policy "grooming_insert_member" on public.grooming_records
  for insert with check (public.is_pet_member(pet_id, auth.uid()));
create policy "grooming_update_member" on public.grooming_records
  for update using (public.is_pet_member(pet_id, auth.uid()));
create policy "grooming_delete_member" on public.grooming_records
  for delete using (public.is_pet_member(pet_id, auth.uid()));

-- exercise_sessions
drop policy if exists "exercise_select_own" on public.exercise_sessions;
drop policy if exists "exercise_insert_own" on public.exercise_sessions;
drop policy if exists "exercise_update_own" on public.exercise_sessions;
drop policy if exists "exercise_delete_own" on public.exercise_sessions;

create policy "exercise_select_member" on public.exercise_sessions
  for select using (public.is_pet_member(pet_id, auth.uid()));
create policy "exercise_insert_member" on public.exercise_sessions
  for insert with check (public.is_pet_member(pet_id, auth.uid()));
create policy "exercise_update_member" on public.exercise_sessions
  for update using (public.is_pet_member(pet_id, auth.uid()));
create policy "exercise_delete_member" on public.exercise_sessions
  for delete using (public.is_pet_member(pet_id, auth.uid()));

-- feeding_logs
drop policy if exists "feeding_logs_select_own" on public.feeding_logs;
drop policy if exists "feeding_logs_insert_own" on public.feeding_logs;
drop policy if exists "feeding_logs_update_own" on public.feeding_logs;
drop policy if exists "feeding_logs_delete_own" on public.feeding_logs;

create policy "feeding_logs_select_member" on public.feeding_logs
  for select using (public.is_pet_member(pet_id, auth.uid()));
create policy "feeding_logs_insert_member" on public.feeding_logs
  for insert with check (public.is_pet_member(pet_id, auth.uid()));
create policy "feeding_logs_update_member" on public.feeding_logs
  for update using (public.is_pet_member(pet_id, auth.uid()));
create policy "feeding_logs_delete_member" on public.feeding_logs
  for delete using (public.is_pet_member(pet_id, auth.uid()));

-- visual_assessments
drop policy if exists "visual_assessments_own" on public.visual_assessments;
create policy "visual_assessments_member_select" on public.visual_assessments
  for select using (public.is_pet_member(pet_id, auth.uid()));
create policy "visual_assessments_member_insert" on public.visual_assessments
  for insert with check (auth.uid() = user_id and public.is_pet_member(pet_id, auth.uid()));
create policy "visual_assessments_own_update" on public.visual_assessments
  for update using (auth.uid() = user_id);
create policy "visual_assessments_own_delete" on public.visual_assessments
  for delete using (auth.uid() = user_id);

-- behavior_analyses
drop policy if exists "behavior_analyses_own" on public.behavior_analyses;
create policy "behavior_analyses_member_select" on public.behavior_analyses
  for select using (public.is_pet_member(pet_id, auth.uid()));
create policy "behavior_analyses_own_insert" on public.behavior_analyses
  for insert with check (auth.uid() = user_id and public.is_pet_member(pet_id, auth.uid()));
create policy "behavior_analyses_own_update" on public.behavior_analyses
  for update using (auth.uid() = user_id);
