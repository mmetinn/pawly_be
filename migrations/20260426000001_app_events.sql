-- Lightweight custom telemetry table.
-- No external SDK — all events stay in our own DB.
-- user_id is nullable to allow pre-auth app_first_open events.

create table public.app_events (
  id           uuid        primary key default uuid_generate_v4(),
  user_id      uuid        references public.profiles(id) on delete cascade,
  event_name   text        not null check (event_name in (
    'app_first_open',
    'sign_up_completed',
    'pet_first_added',
    'reminder_first_added',
    'vaccination_first_added',
    'paywall_viewed',
    'purchase_started',
    'purchase_completed'
  )),
  platform     text        check (platform in ('ios', 'android')),
  app_version  text,
  created_at   timestamptz not null default now()
);

create index idx_app_events_user_id    on public.app_events(user_id);
create index idx_app_events_name       on public.app_events(event_name);
create index idx_app_events_created_at on public.app_events(created_at desc);

alter table public.app_events enable row level security;

-- Users can insert their own events (user_id matches auth.uid() OR is null for pre-auth)
create policy "app_events_insert"
  on public.app_events for insert
  with check (auth.uid() = user_id or user_id is null);

-- Users can read only their own events
create policy "app_events_select_own"
  on public.app_events for select
  using (auth.uid() = user_id);
