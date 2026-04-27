-- Exercise sessions + GPS routes

create table public.exercise_sessions (
  id              uuid        primary key default uuid_generate_v4(),
  pet_id          uuid        not null references public.pets(id) on delete cascade,
  activity_type   text        not null default 'walk'
                              check (activity_type in (
                                'walk','run','play','training','swim',
                                'park_visit','fetch','hike','leash_walk','other'
                              )),
  started_at      timestamptz not null,
  duration_minutes int        not null check (duration_minutes > 0),
  distance_km     numeric(5,2),
  intensity       text        not null default 'moderate'
                              check (intensity in ('low','moderate','high')),
  location_name   text,
  location_lat    numeric,
  location_lng    numeric,
  weather         text,
  mood            text        check (mood in ('happy','normal','tired','reluctant','energetic')),
  bathroom_breaks int         not null default 0,
  met_other_pets  boolean     not null default false,
  notes           text,
  photo_urls      text[],
  logged_by       uuid        references auth.users(id) on delete set null,
  is_gps_tracked  boolean     not null default false,
  external_source text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

alter table public.exercise_sessions enable row level security;

create policy "exercise_select_own" on public.exercise_sessions
  for select using (exists (select 1 from public.pets where pets.id = exercise_sessions.pet_id and pets.user_id = auth.uid()));
create policy "exercise_insert_own" on public.exercise_sessions
  for insert with check (exists (select 1 from public.pets where pets.id = exercise_sessions.pet_id and pets.user_id = auth.uid()));
create policy "exercise_update_own" on public.exercise_sessions
  for update using (exists (select 1 from public.pets where pets.id = exercise_sessions.pet_id and pets.user_id = auth.uid()));
create policy "exercise_delete_own" on public.exercise_sessions
  for delete using (exists (select 1 from public.pets where pets.id = exercise_sessions.pet_id and pets.user_id = auth.uid()));

create index idx_exercise_pet_time on public.exercise_sessions(pet_id, started_at desc);

-- ── GPS routes ────────────────────────────────────────────────────────────────

create table public.exercise_routes (
  id               uuid    primary key default uuid_generate_v4(),
  session_id       uuid    not null references public.exercise_sessions(id) on delete cascade,
  coordinates      jsonb   not null,  -- [{lat, lng, timestamp}, ...]
  max_speed_kmh    numeric,
  elevation_gain_m numeric
);

alter table public.exercise_routes enable row level security;

create policy "exercise_routes_select_own" on public.exercise_routes
  for select using (exists (
    select 1 from public.exercise_sessions s join public.pets p on p.id = s.pet_id
    where s.id = exercise_routes.session_id and p.user_id = auth.uid()
  ));
create policy "exercise_routes_insert_own" on public.exercise_routes
  for insert with check (exists (
    select 1 from public.exercise_sessions s join public.pets p on p.id = s.pet_id
    where s.id = exercise_routes.session_id and p.user_id = auth.uid()
  ));

-- pets table: exercise daily goal
alter table public.pets
  add column if not exists exercise_goal_minutes int;
