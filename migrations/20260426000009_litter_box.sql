-- Litter box tracking (cat-specific)
-- litter_boxes + litter_cleaning_logs + litter_usage_observations

create table public.litter_boxes (
  id               uuid        primary key default uuid_generate_v4(),
  user_id          uuid        not null references auth.users(id) on delete cascade,
  name             text        not null,
  location         text,
  box_type         text        not null default 'open'
                               check (box_type in ('open','covered','self_cleaning','top_entry','other')),
  litter_type      text        check (litter_type in ('clumping','non_clumping','crystal','pine','paper','tofu','other')),
  litter_brand     text,
  shared_by_pet_ids uuid[],
  is_active        boolean     not null default true,
  notes            text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

alter table public.litter_boxes enable row level security;

create policy "litter_boxes_select_own" on public.litter_boxes
  for select using (auth.uid() = user_id);
create policy "litter_boxes_insert_own" on public.litter_boxes
  for insert with check (auth.uid() = user_id);
create policy "litter_boxes_update_own" on public.litter_boxes
  for update using (auth.uid() = user_id);
create policy "litter_boxes_delete_own" on public.litter_boxes
  for delete using (auth.uid() = user_id);

create index idx_litter_boxes_user on public.litter_boxes(user_id, is_active);

-- ── Cleaning logs ─────────────────────────────────────────────────────────────

create table public.litter_cleaning_logs (
  id              uuid        primary key default uuid_generate_v4(),
  litter_box_id   uuid        not null references public.litter_boxes(id) on delete cascade,
  cleaned_at      timestamptz not null default now(),
  cleaning_type   text        not null default 'scoop'
                              check (cleaning_type in ('scoop','partial_change','full_change','wash','deep_clean')),
  litter_added_kg numeric(4,2),
  notes           text,
  cleaned_by      uuid        references auth.users(id) on delete set null,
  created_at      timestamptz not null default now()
);

alter table public.litter_cleaning_logs enable row level security;

create policy "litter_logs_select_own" on public.litter_cleaning_logs
  for select using (
    exists (select 1 from public.litter_boxes where litter_boxes.id = litter_cleaning_logs.litter_box_id and litter_boxes.user_id = auth.uid())
  );
create policy "litter_logs_insert_own" on public.litter_cleaning_logs
  for insert with check (
    exists (select 1 from public.litter_boxes where litter_boxes.id = litter_cleaning_logs.litter_box_id and litter_boxes.user_id = auth.uid())
  );
create policy "litter_logs_delete_own" on public.litter_cleaning_logs
  for delete using (
    exists (select 1 from public.litter_boxes where litter_boxes.id = litter_cleaning_logs.litter_box_id and litter_boxes.user_id = auth.uid())
  );

create index idx_litter_logs_box_time on public.litter_cleaning_logs(litter_box_id, cleaned_at desc);

-- ── Usage observations ────────────────────────────────────────────────────────

create table public.litter_usage_observations (
  id               uuid        primary key default uuid_generate_v4(),
  litter_box_id    uuid        references public.litter_boxes(id) on delete set null,
  pet_id           uuid        references public.pets(id) on delete set null,
  observed_at      timestamptz not null default now(),
  observation_type text        not null default 'urine'
                               check (observation_type in ('urine','stool','both','attempted_no_result','outside_box','blood_observed')),
  urine_amount     text        check (urine_amount in ('normal','small','large','very_large')),
  stool_consistency text       check (stool_consistency in ('normal','soft','diarrhea','hard','constipation')),
  color_concern    boolean     not null default false,
  notes            text,
  photo_url        text,
  logged_by        uuid        references auth.users(id) on delete set null,
  created_at       timestamptz not null default now()
);

alter table public.litter_usage_observations enable row level security;

create policy "litter_obs_select_own" on public.litter_usage_observations
  for select using (auth.uid() = logged_by or exists (
    select 1 from public.pets where pets.id = litter_usage_observations.pet_id and pets.user_id = auth.uid()
  ));
create policy "litter_obs_insert_own" on public.litter_usage_observations
  for insert with check (auth.uid() = logged_by);
create policy "litter_obs_delete_own" on public.litter_usage_observations
  for delete using (auth.uid() = logged_by);

create index idx_litter_obs_pet_time on public.litter_usage_observations(pet_id, observed_at desc);
