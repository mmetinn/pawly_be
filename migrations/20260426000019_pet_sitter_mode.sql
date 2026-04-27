-- Pet Sitter Mode: tatil senaryosu için bakım yönetimi
-- Migration: 000019

-- ─── Enums ────────────────────────────────────────────────────────────────────

create type public.sitter_status as enum ('scheduled', 'active', 'completed', 'cancelled');

create type public.care_section as enum (
  'feeding', 'medications', 'walking', 'behavior',
  'house_rules', 'emergency', 'favorites', 'avoid', 'other'
);

create type public.handoff_note_type as enum (
  'daily_update', 'concern', 'question', 'emergency', 'completion'
);

create type public.handoff_written_by_role as enum ('owner', 'sitter');

-- ─── sitter_assignments ───────────────────────────────────────────────────────

create table public.sitter_assignments (
  id                       uuid primary key default gen_random_uuid(),
  pet_member_id            uuid references public.pet_members(id) on delete set null,
  pet_id                   uuid not null references public.pets(id) on delete cascade,
  owner_id                 uuid not null references auth.users(id) on delete cascade,
  sitter_user_id           uuid references auth.users(id) on delete set null,
  sitter_name              text not null,
  sitter_phone             text,
  sitter_email             text,
  starts_at                timestamptz not null,
  ends_at                  timestamptz not null,
  emergency_contact_owner  boolean not null default true,
  emergency_contact_vet    boolean not null default true,
  can_authorize_vet        boolean not null default false,
  status                   public.sitter_status not null default 'scheduled',
  completion_summary       jsonb,
  owner_private_note       text,
  owner_rating             smallint check (owner_rating between 1 and 5),
  web_access_token         text unique,
  onboarding_completed_at  timestamptz,
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now()
);

-- ─── care_instructions ────────────────────────────────────────────────────────

create table public.care_instructions (
  id          uuid primary key default gen_random_uuid(),
  pet_id      uuid not null references public.pets(id) on delete cascade,
  section     public.care_section not null,
  content     text not null,
  photo_urls  text[],
  sort_order  int not null default 0,
  is_essential boolean not null default false,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- ─── sitter_handoff_notes ─────────────────────────────────────────────────────

create table public.sitter_handoff_notes (
  id                    uuid primary key default gen_random_uuid(),
  sitter_assignment_id  uuid not null references public.sitter_assignments(id) on delete cascade,
  note_type             public.handoff_note_type not null default 'daily_update',
  content               text not null,
  photo_urls            text[],
  written_by            uuid references auth.users(id) on delete set null,
  written_by_role       public.handoff_written_by_role not null,
  read_at               timestamptz,
  created_at            timestamptz not null default now()
);

-- ─── Indexes ──────────────────────────────────────────────────────────────────

create index sitter_assignments_pet_status_idx on public.sitter_assignments(pet_id, status);
create index sitter_assignments_owner_idx on public.sitter_assignments(owner_id, status);
create index sitter_assignments_sitter_idx on public.sitter_assignments(sitter_user_id, status);
create index sitter_assignments_token_idx on public.sitter_assignments(web_access_token) where web_access_token is not null;
create index care_instructions_pet_section_idx on public.care_instructions(pet_id, section, sort_order);
create index handoff_notes_assignment_idx on public.sitter_handoff_notes(sitter_assignment_id, created_at desc);

-- ─── RLS ──────────────────────────────────────────────────────────────────────

alter table public.sitter_assignments enable row level security;
alter table public.care_instructions enable row level security;
alter table public.sitter_handoff_notes enable row level security;

-- sitter_assignments: owner full CRUD, sitter select
create policy "sitter_assign_owner_all" on public.sitter_assignments
  for all using (owner_id = auth.uid());

create policy "sitter_assign_sitter_select" on public.sitter_assignments
  for select using (sitter_user_id = auth.uid());

-- care_instructions: pet members can read; owner/co_owner can write
create policy "care_instr_member_select" on public.care_instructions
  for select using (public.is_pet_member(pet_id, auth.uid()));

create policy "care_instr_owner_insert" on public.care_instructions
  for insert with check (
    exists (
      select 1 from public.pet_members pm
      where pm.pet_id = care_instructions.pet_id
        and pm.user_id = auth.uid()
        and pm.role in ('owner', 'co_owner')
        and pm.status = 'active'
    )
  );

create policy "care_instr_owner_update" on public.care_instructions
  for update using (
    exists (
      select 1 from public.pet_members pm
      where pm.pet_id = care_instructions.pet_id
        and pm.user_id = auth.uid()
        and pm.role in ('owner', 'co_owner')
        and pm.status = 'active'
    )
  );

create policy "care_instr_owner_delete" on public.care_instructions
  for delete using (
    exists (
      select 1 from public.pet_members pm
      where pm.pet_id = care_instructions.pet_id
        and pm.user_id = auth.uid()
        and pm.role in ('owner', 'co_owner')
        and pm.status = 'active'
    )
  );

-- sitter_handoff_notes: owner and assigned sitter
create policy "handoff_notes_owner_all" on public.sitter_handoff_notes
  for all using (
    exists (
      select 1 from public.sitter_assignments sa
      where sa.id = sitter_handoff_notes.sitter_assignment_id
        and sa.owner_id = auth.uid()
    )
  );

create policy "handoff_notes_sitter_all" on public.sitter_handoff_notes
  for all using (
    exists (
      select 1 from public.sitter_assignments sa
      where sa.id = sitter_handoff_notes.sitter_assignment_id
        and sa.sitter_user_id = auth.uid()
    )
  );
