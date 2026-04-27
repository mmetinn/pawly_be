-- Pet Share Links: veteriner ile kayıt paylaşımı
-- Migration: 000018

-- Share types enum
create type public.share_type as enum (
  'full_record',
  'vaccination_only',
  'emergency_summary',
  'custom'
);

-- Share links table
create table public.pet_share_links (
  id                uuid primary key default gen_random_uuid(),
  pet_id            uuid not null references public.pets(id) on delete cascade,
  created_by        uuid not null references auth.users(id) on delete cascade,
  share_token       text not null unique,
  share_type        public.share_type not null default 'full_record',
  included_sections jsonb not null default '{
    "basic_info": true,
    "vaccinations": true,
    "medications": true,
    "vet_visits": true,
    "surgeries": true,
    "weight_history": true,
    "parasites": true,
    "feeding": false,
    "exercise": false,
    "photos": true
  }'::jsonb,
  date_range_start  date,
  date_range_end    date,
  recipient_name    text,
  recipient_email   text,
  access_passcode   text,
  expires_at        timestamptz not null default (now() + interval '7 days'),
  max_views         int,
  view_count        int not null default 0,
  last_viewed_at    timestamptz,
  last_viewed_ip    text,
  is_active         boolean not null default true,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

-- Audit log for share link views
create table public.share_link_views (
  id                    uuid primary key default gen_random_uuid(),
  share_link_id         uuid not null references public.pet_share_links(id) on delete cascade,
  viewed_at             timestamptz not null default now(),
  ip_address            text,
  user_agent            text,
  country               text,
  is_passcode_attempt   boolean not null default false,
  passcode_correct      boolean
);

-- Indexes
create index pet_share_links_token_idx on public.pet_share_links(share_token);
create index pet_share_links_pet_active_idx on public.pet_share_links(pet_id, is_active);
create index pet_share_links_created_by_idx on public.pet_share_links(created_by);
create index share_link_views_link_idx on public.share_link_views(share_link_id, viewed_at desc);

-- RLS
alter table public.pet_share_links enable row level security;
alter table public.share_link_views enable row level security;

-- pet_share_links: owner and co_owner can CRUD
create policy "share_links_select_owner" on public.pet_share_links
  for select using (
    exists (
      select 1 from public.pet_members pm
      where pm.pet_id = pet_share_links.pet_id
        and pm.user_id = auth.uid()
        and pm.role in ('owner', 'co_owner')
        and pm.status = 'active'
    )
  );

create policy "share_links_insert_owner" on public.pet_share_links
  for insert with check (
    created_by = auth.uid() and
    exists (
      select 1 from public.pet_members pm
      where pm.pet_id = pet_share_links.pet_id
        and pm.user_id = auth.uid()
        and pm.role in ('owner', 'co_owner')
        and pm.status = 'active'
    )
  );

create policy "share_links_update_owner" on public.pet_share_links
  for update using (
    exists (
      select 1 from public.pet_members pm
      where pm.pet_id = pet_share_links.pet_id
        and pm.user_id = auth.uid()
        and pm.role in ('owner', 'co_owner')
        and pm.status = 'active'
    )
  );

create policy "share_links_delete_owner" on public.pet_share_links
  for delete using (
    exists (
      select 1 from public.pet_members pm
      where pm.pet_id = pet_share_links.pet_id
        and pm.user_id = auth.uid()
        and pm.role in ('owner', 'co_owner')
        and pm.status = 'active'
    )
  );

-- share_link_views: owner can read their link views
create policy "share_link_views_select" on public.share_link_views
  for select using (
    exists (
      select 1 from public.pet_share_links psl
      join public.pet_members pm on pm.pet_id = psl.pet_id
      where psl.id = share_link_views.share_link_id
        and pm.user_id = auth.uid()
        and pm.role in ('owner', 'co_owner')
        and pm.status = 'active'
    )
  );

-- Edge Function will insert via service_role key (bypasses RLS)
-- so no insert policy needed for share_link_views
