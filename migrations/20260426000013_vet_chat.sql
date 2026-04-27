-- Migration: vet_chat (AI vet assistant)
-- LEGAL WARNING: Before production launch, verify compliance with TR medical device
-- regulations, KVKK (Personal Data Protection Law), and have legal counsel review
-- disclaimers and Terms of Service. Do NOT launch without legal sign-off.

-- ─── vet_chat_conversations ───────────────────────────────────────────────────

create table public.vet_chat_conversations (
  id                     uuid        primary key default uuid_generate_v4(),
  user_id                uuid        not null references auth.users(id) on delete cascade,
  pet_id                 uuid        references public.pets(id) on delete set null,
  title                  text,
  status                 text        not null default 'active'
                           check (status in ('active','archived','flagged')),
  emergency_detected     boolean     not null default false,
  emergency_referred_at  timestamptz,
  last_message_at        timestamptz not null default now(),
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now()
);

alter table public.vet_chat_conversations enable row level security;

create policy "vetchat_conv_own" on public.vet_chat_conversations
  for all using (auth.uid() = user_id);

create index idx_vetchat_conv_user_last
  on public.vet_chat_conversations(user_id, last_message_at desc);

-- ─── vet_chat_messages ────────────────────────────────────────────────────────

create table public.vet_chat_messages (
  id               uuid        primary key default uuid_generate_v4(),
  conversation_id  uuid        not null references public.vet_chat_conversations(id) on delete cascade,
  role             text        not null check (role in ('user','assistant','system')),
  content          text        not null,
  metadata         jsonb,
  flagged          boolean     not null default false,
  flag_reason      text,
  created_at       timestamptz not null default now()
);

alter table public.vet_chat_messages enable row level security;

create policy "vetchat_msg_own" on public.vet_chat_messages
  for all using (
    exists (
      select 1 from public.vet_chat_conversations c
      where c.id = conversation_id and c.user_id = auth.uid()
    )
  );

create index idx_vetchat_msg_conv_time
  on public.vet_chat_messages(conversation_id, created_at);

-- ─── vet_chat_usage ───────────────────────────────────────────────────────────

create table public.vet_chat_usage (
  id                 uuid        primary key default uuid_generate_v4(),
  user_id            uuid        not null references auth.users(id) on delete cascade,
  date               date        not null,
  message_count      int         not null default 0,
  total_tokens       int         not null default 0,
  estimated_cost_usd numeric(10,6) not null default 0,
  tier_at_time       text        not null default 'free',
  unique(user_id, date)
);

alter table public.vet_chat_usage enable row level security;

create policy "vetchat_usage_own" on public.vet_chat_usage
  for all using (auth.uid() = user_id);

create index idx_vetchat_usage_user_date
  on public.vet_chat_usage(user_id, date);

-- ─── vet_chat_feedback ────────────────────────────────────────────────────────

create table public.vet_chat_feedback (
  id          uuid        primary key default uuid_generate_v4(),
  message_id  uuid        not null references public.vet_chat_messages(id) on delete cascade,
  user_id     uuid        not null references auth.users(id) on delete cascade,
  rating      text        not null check (rating in ('helpful','unhelpful','incorrect','unsafe')),
  comment     text,
  created_at  timestamptz not null default now(),
  unique(message_id, user_id)
);

alter table public.vet_chat_feedback enable row level security;

create policy "vetchat_feedback_own" on public.vet_chat_feedback
  for all using (auth.uid() = user_id);

-- ─── vet_chat_consent ─────────────────────────────────────────────────────────

create table public.vet_chat_consent (
  user_id      uuid        primary key references auth.users(id) on delete cascade,
  consented_at timestamptz not null default now(),
  version      text        not null default '1.0'
);

alter table public.vet_chat_consent enable row level security;

create policy "vetchat_consent_own" on public.vet_chat_consent
  for all using (auth.uid() = user_id);
