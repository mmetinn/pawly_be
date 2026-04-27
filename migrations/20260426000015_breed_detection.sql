-- Migration: breed_detection (AI breed prediction)
-- Low legal risk — entertainment/fun feature, no health claims.
-- Disclaimer: "Eğlence amaçlıdır, DNA testi değildir"

create table public.breed_predictions (
  id               uuid        primary key default uuid_generate_v4(),
  user_id          uuid        not null references auth.users(id) on delete cascade,
  pet_id           uuid        references public.pets(id) on delete set null,
  species          text        not null check (species in ('dog','cat')),
  photo_url        text        not null,
  predictions      jsonb       not null default '[]',
  personality_notes text,
  tokens_used      int,
  shared_count     int         not null default 0,
  user_feedback    text        check (user_feedback in ('correct','incorrect','partial')),
  actual_breed     text,
  created_at       timestamptz not null default now()
);

alter table public.breed_predictions enable row level security;

create policy "breed_predictions_own" on public.breed_predictions
  for all using (auth.uid() = user_id);

create index idx_breed_predictions_user_date
  on public.breed_predictions(user_id, created_at desc);

create index idx_breed_predictions_pet
  on public.breed_predictions(pet_id, created_at desc);

-- ─── Quota ─────────────────────────────────────────────────────────────��─────

create table public.breed_prediction_quota (
  id      uuid  primary key default uuid_generate_v4(),
  user_id uuid  not null references auth.users(id) on delete cascade,
  month   date  not null,
  count   int   not null default 0,
  tier    text  not null default 'free',
  unique(user_id, month)
);

alter table public.breed_prediction_quota enable row level security;

create policy "breed_quota_own" on public.breed_prediction_quota
  for all using (auth.uid() = user_id);

-- Storage bucket: breed-photos (private)
-- Create via CLI: npx supabase storage create breed-photos --private
-- Photos auto-deleted after 6 months (set lifecycle policy in Supabase dashboard)
