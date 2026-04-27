-- Migration: behavior_analysis (AI Pattern & Behavior Analysis)
-- Pro+ only feature. Requires active usage of feeding/exercise/medications/weight modules.
-- Deploy last — value depends on existing data from other modules.
-- LEGAL: "Pattern detection amaçlıdır, tıbbi teşhis değildir."

create table public.behavior_analyses (
  id                  uuid        primary key default uuid_generate_v4(),
  user_id             uuid        not null references auth.users(id) on delete cascade,
  pet_id              uuid        not null references public.pets(id) on delete cascade,
  analysis_type       text        not null check (analysis_type in (
                        'monthly_general','health_trends','feeding_pattern',
                        'activity_pattern','medication_adherence',
                        'concerning_changes','custom_question'
                      )),
  time_range_start    date        not null,
  time_range_end      date        not null,
  custom_question     text,
  input_data_summary  jsonb,
  ai_response         text        not null,
  key_insights        jsonb       not null default '[]',
  concern_count       int         not null default 0,
  has_urgent_finding  boolean     not null default false,
  tokens_used         int,
  user_rating         text        check (user_rating in ('helpful','unhelpful','incorrect')),
  created_at          timestamptz not null default now()
);

alter table public.behavior_analyses enable row level security;

create policy "behavior_analyses_own" on public.behavior_analyses
  for all using (auth.uid() = user_id);

create index idx_behavior_analyses_pet_date
  on public.behavior_analyses(pet_id, created_at desc);

create index idx_behavior_analyses_user_date
  on public.behavior_analyses(user_id, created_at desc);

-- ─── Subscriptions ────────────────────────────────────────────────────────────

create table public.behavior_analysis_subscriptions (
  id                    uuid        primary key default uuid_generate_v4(),
  user_id               uuid        not null references auth.users(id) on delete cascade,
  pet_id                uuid        not null references public.pets(id) on delete cascade,
  analysis_type         text        not null,
  frequency             text        not null default 'monthly'
                          check (frequency in ('weekly','monthly','never')),
  last_run_at           timestamptz,
  next_run_at           timestamptz,
  notification_enabled  boolean     not null default true,
  created_at            timestamptz not null default now(),
  unique(user_id, pet_id, analysis_type)
);

alter table public.behavior_analysis_subscriptions enable row level security;

create policy "behavior_subs_own" on public.behavior_analysis_subscriptions
  for all using (auth.uid() = user_id);

create index idx_behavior_subs_user_freq
  on public.behavior_analysis_subscriptions(user_id, frequency);
