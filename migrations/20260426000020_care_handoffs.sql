-- Care Handoffs: görev bazlı aile koordinasyonu
-- Migration: 000020

create type public.handoff_task_type as enum (
  'feeding', 'medication', 'walking', 'play',
  'grooming', 'vet_visit', 'general', 'check_in'
);

create type public.handoff_priority as enum ('low', 'normal', 'high', 'urgent');

create type public.handoff_status as enum ('pending', 'completed', 'skipped', 'cancelled');

create table public.care_handoffs (
  id                       uuid primary key default gen_random_uuid(),
  pet_id                   uuid not null references public.pets(id) on delete cascade,
  created_by               uuid not null references auth.users(id) on delete cascade,
  assigned_to              uuid references auth.users(id) on delete set null,
  title                    text not null,
  description              text,
  task_type                public.handoff_task_type not null default 'general',
  scheduled_for            timestamptz,
  is_recurring             boolean not null default false,
  recurrence_rule          jsonb,
  priority                 public.handoff_priority not null default 'normal',
  status                   public.handoff_status not null default 'pending',
  completed_by             uuid references auth.users(id) on delete set null,
  completed_at             timestamptz,
  completion_note          text,
  completion_photo_url     text,
  linked_log_id            uuid,
  linked_log_type          text,
  reminder_minutes_before  int not null default 15,
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now()
);

create table public.care_handoff_comments (
  id          uuid primary key default gen_random_uuid(),
  handoff_id  uuid not null references public.care_handoffs(id) on delete cascade,
  user_id     uuid not null references auth.users(id) on delete cascade,
  comment     text not null,
  created_at  timestamptz not null default now()
);

-- Indexes
create index care_handoffs_pet_status_idx on public.care_handoffs(pet_id, status, scheduled_for);
create index care_handoffs_assigned_idx on public.care_handoffs(assigned_to, status);
create index care_handoffs_pending_scheduled_idx on public.care_handoffs(scheduled_for) where status = 'pending';
create index care_handoff_comments_handoff_idx on public.care_handoff_comments(handoff_id, created_at);

-- RLS
alter table public.care_handoffs enable row level security;
alter table public.care_handoff_comments enable row level security;

-- Pet members can read all handoffs for their pet
create policy "handoffs_member_select" on public.care_handoffs
  for select using (public.is_pet_member(pet_id, auth.uid()));

-- Members can insert handoffs for pets they're part of
create policy "handoffs_member_insert" on public.care_handoffs
  for insert with check (
    created_by = auth.uid() and
    public.is_pet_member(pet_id, auth.uid())
  );

-- Creator or pet owner can update
create policy "handoffs_update" on public.care_handoffs
  for update using (
    created_by = auth.uid() or
    exists (
      select 1 from public.pet_members pm
      where pm.pet_id = care_handoffs.pet_id
        and pm.user_id = auth.uid()
        and pm.role in ('owner', 'co_owner')
        and pm.status = 'active'
    )
  );

-- Creator or pet owner can delete
create policy "handoffs_delete" on public.care_handoffs
  for delete using (
    created_by = auth.uid() or
    exists (
      select 1 from public.pet_members pm
      where pm.pet_id = care_handoffs.pet_id
        and pm.user_id = auth.uid()
        and pm.role in ('owner', 'co_owner')
        and pm.status = 'active'
    )
  );

-- Comments: any pet member can read/write
create policy "handoff_comments_select" on public.care_handoff_comments
  for select using (
    exists (
      select 1 from public.care_handoffs ch
      where ch.id = care_handoff_comments.handoff_id
        and public.is_pet_member(ch.pet_id, auth.uid())
    )
  );

create policy "handoff_comments_insert" on public.care_handoff_comments
  for insert with check (
    user_id = auth.uid() and
    exists (
      select 1 from public.care_handoffs ch
      where ch.id = care_handoff_comments.handoff_id
        and public.is_pet_member(ch.pet_id, auth.uid())
    )
  );
