-- Migration: visual_assessments (Vision AI feature)
-- LEGAL WARNING: This feature performs AI-based visual observation of pet photos.
-- It is NOT a diagnostic tool. Before production launch:
-- - Verify it does not qualify as a "medical device" under TR regulations
-- - Have legal counsel review all disclaimers and consent flows
-- - KVKK compliance for photo data (health-related sensitive data)
-- This feature carries HIGHER legal risk than the text-based vet chat.
-- DO NOT launch without legal sign-off.

-- ─── visual_assessments ───────────────────────────────────────────────────────

create table public.visual_assessments (
  id                     uuid        primary key default uuid_generate_v4(),
  user_id                uuid        not null references auth.users(id) on delete cascade,
  pet_id                 uuid        not null references public.pets(id) on delete cascade,
  assessment_category    text        not null
                           check (assessment_category in (
                             'skin_observation','ear_check','dental_observation',
                             'body_condition','nail_check','wound_recovery','other_observation'
                           )),
  photo_url              text        not null,
  additional_context     text,
  ai_response            text        not null,
  ai_concern_level       text
                           check (ai_concern_level in ('normal','monitor','vet_recommended','urgent')),
  tokens_used            int,
  flagged_for_review     boolean     not null default false,
  user_feedback          text
                           check (user_feedback in ('helpful','unhelpful','incorrect')),
  linked_to_vet_visit_id uuid        references public.vet_visits(id) on delete set null,
  created_at             timestamptz not null default now()
);

alter table public.visual_assessments enable row level security;

create policy "visual_assessments_own" on public.visual_assessments
  for all using (auth.uid() = user_id);

create index idx_visual_assessments_user_date
  on public.visual_assessments(user_id, created_at desc);

create index idx_visual_assessments_pet_cat_date
  on public.visual_assessments(pet_id, assessment_category, created_at desc);

-- ─── visual_assessment_quota ─────────────────────────────────────────────────

create table public.visual_assessment_quota (
  id      uuid    primary key default uuid_generate_v4(),
  user_id uuid    not null references auth.users(id) on delete cascade,
  date    date    not null,
  count   int     not null default 0,
  tier    text    not null default 'premium',
  unique(user_id, date)
);

alter table public.visual_assessment_quota enable row level security;

create policy "visual_quota_own" on public.visual_assessment_quota
  for all using (auth.uid() = user_id);

create index idx_visual_quota_user_date
  on public.visual_assessment_quota(user_id, date);

-- ─── Storage bucket ───────────────────────────────────────────────────────────
-- Create via Supabase dashboard or CLI:
-- supabase storage create visual-assessments --private
-- Signed URL TTL: 3600 seconds (1 hour)
-- Note: bucket creation in SQL not supported in all Supabase versions.
-- Run: npx supabase storage create visual-assessments after migration.
