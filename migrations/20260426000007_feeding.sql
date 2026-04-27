-- Feeding: pet_foods + feeding_plans + feeding_logs

create table public.pet_foods (
  id                  uuid        primary key default uuid_generate_v4(),
  pet_id              uuid        not null references public.pets(id) on delete cascade,
  food_name           text        not null,
  brand               text,
  food_type           text        not null default 'dry'
                                  check (food_type in ('dry','wet','raw','home_cooked','treat','mixed')),
  life_stage          text        check (life_stage in ('puppy','kitten','adult','senior','all_life_stages')),
  special_diet        text[],
  calories_per_100g   numeric,
  package_size_kg     numeric,
  cost_per_package    numeric(10,2),
  currency            text        not null default 'TRY',
  purchase_location   text,
  is_current          boolean     not null default true,
  prescribed_by_vet   boolean     not null default false,
  notes               text,
  photo_url           text,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

alter table public.pet_foods enable row level security;

create policy "pet_foods_select_own" on public.pet_foods
  for select using (exists (select 1 from public.pets where pets.id = pet_foods.pet_id and pets.user_id = auth.uid()));
create policy "pet_foods_insert_own" on public.pet_foods
  for insert with check (exists (select 1 from public.pets where pets.id = pet_foods.pet_id and pets.user_id = auth.uid()));
create policy "pet_foods_update_own" on public.pet_foods
  for update using (exists (select 1 from public.pets where pets.id = pet_foods.pet_id and pets.user_id = auth.uid()));
create policy "pet_foods_delete_own" on public.pet_foods
  for delete using (exists (select 1 from public.pets where pets.id = pet_foods.pet_id and pets.user_id = auth.uid()));

create index idx_pet_foods_pet on public.pet_foods(pet_id, is_current);

-- ── Feeding plans ─────────────────────────────────────────────────────────────

create table public.feeding_plans (
  id              uuid    primary key default uuid_generate_v4(),
  pet_id          uuid    not null references public.pets(id) on delete cascade,
  food_id         uuid    not null references public.pet_foods(id) on delete cascade,
  meal_name       text    not null,
  time_of_day     time,
  amount_value    numeric not null,
  amount_unit     text    not null default 'grams'
                          check (amount_unit in ('grams','cups','cans','pieces','tablespoons')),
  amount_grams    numeric,
  days_of_week    int[]   not null default '{1,2,3,4,5,6,7}',
  reminder_enabled boolean not null default false,
  is_active       boolean not null default true,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

alter table public.feeding_plans enable row level security;

create policy "feeding_plans_select_own" on public.feeding_plans
  for select using (exists (select 1 from public.pets where pets.id = feeding_plans.pet_id and pets.user_id = auth.uid()));
create policy "feeding_plans_insert_own" on public.feeding_plans
  for insert with check (exists (select 1 from public.pets where pets.id = feeding_plans.pet_id and pets.user_id = auth.uid()));
create policy "feeding_plans_update_own" on public.feeding_plans
  for update using (exists (select 1 from public.pets where pets.id = feeding_plans.pet_id and pets.user_id = auth.uid()));
create policy "feeding_plans_delete_own" on public.feeding_plans
  for delete using (exists (select 1 from public.pets where pets.id = feeding_plans.pet_id and pets.user_id = auth.uid()));

create index idx_feeding_plans_pet on public.feeding_plans(pet_id, is_active);

-- ── Feeding logs ──────────────────────────────────────────────────────────────

create table public.feeding_logs (
  id           uuid        primary key default uuid_generate_v4(),
  pet_id       uuid        not null references public.pets(id) on delete cascade,
  food_id      uuid        references public.pet_foods(id) on delete set null,
  plan_id      uuid        references public.feeding_plans(id) on delete set null,
  fed_at       timestamptz not null default now(),
  amount_value numeric,
  amount_unit  text        check (amount_unit in ('grams','cups','cans','pieces','tablespoons')),
  amount_grams numeric,
  was_finished text        not null default 'all'
                           check (was_finished in ('all','most','half','little','none')),
  notes        text,
  logged_by    uuid        references auth.users(id) on delete set null,
  created_at   timestamptz not null default now()
);

alter table public.feeding_logs enable row level security;

create policy "feeding_logs_select_own" on public.feeding_logs
  for select using (exists (select 1 from public.pets where pets.id = feeding_logs.pet_id and pets.user_id = auth.uid()));
create policy "feeding_logs_insert_own" on public.feeding_logs
  for insert with check (exists (select 1 from public.pets where pets.id = feeding_logs.pet_id and pets.user_id = auth.uid()));
create policy "feeding_logs_delete_own" on public.feeding_logs
  for delete using (exists (select 1 from public.pets where pets.id = feeding_logs.pet_id and pets.user_id = auth.uid()));

create index idx_feeding_logs_pet_time on public.feeding_logs(pet_id, fed_at desc);
