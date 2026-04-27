-- Subscription Tier System
-- Migration: 000023

-- ─── Enums ────────────────────────────────────────────────────────────────────

create type public.subscription_status as enum (
  'active', 'cancelled', 'expired', 'pending', 'trial'
);

create type public.subscription_source as enum (
  'free', 'app_store', 'play_store', 'web_stripe', 'manual', 'promo', 'gift'
);

create type public.tier_change_reason as enum (
  'upgrade', 'downgrade', 'expiration', 'admin', 'refund', 'gift'
);

create type public.period_type as enum ('daily', 'monthly', 'lifetime');

-- ─── subscription_tiers ───────────────────────────────────────────────────────

create table public.subscription_tiers (
  tier_key        text primary key,
  display_name    text not null,
  display_name_tr text not null,
  sort_order      int not null default 0,
  price_try       numeric(10,2),
  price_usd       numeric(10,2),
  is_active       boolean not null default true,
  badge_color     text,
  badge_icon      text
);

-- ─── tier_features ────────────────────────────────────────────────────────────

create table public.tier_features (
  id              uuid primary key default gen_random_uuid(),
  tier_key        text not null references public.subscription_tiers(tier_key) on delete cascade,
  feature_key     text not null,
  is_enabled      boolean not null default false,
  limit_value     int,        -- null = unlimited, 0 = disabled
  period_type     public.period_type,
  description_tr  text,
  unique(tier_key, feature_key)
);

-- ─── user_subscriptions ───────────────────────────────────────────────────────

create table public.user_subscriptions (
  id                       uuid primary key default gen_random_uuid(),
  user_id                  uuid not null unique references auth.users(id) on delete cascade,
  tier_key                 text not null references public.subscription_tiers(tier_key) default 'free',
  status                   public.subscription_status not null default 'active',
  source                   public.subscription_source not null default 'free',
  external_subscription_id text,
  started_at               timestamptz not null default now(),
  expires_at               timestamptz,
  cancelled_at             timestamptz,
  last_verified_at         timestamptz,
  purchase_amount          numeric(10,2),
  purchase_currency        text,
  notes                    text,
  metadata                 jsonb,
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now()
);

-- ─── tier_change_history ─────────────────────────────────────────────────────

create table public.tier_change_history (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  from_tier   text,
  to_tier     text not null,
  reason      public.tier_change_reason not null,
  changed_at  timestamptz not null default now(),
  metadata    jsonb
);

-- ─── feature_usage_counters ──────────────────────────────────────────────────

create table public.feature_usage_counters (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users(id) on delete cascade,
  feature_key  text not null,
  period_type  public.period_type not null,
  period_start date not null,
  count        int not null default 0,
  unique(user_id, feature_key, period_type, period_start)
);

-- ─── Indexes ─────────────────────────────────────────────────────────────────

create index user_subscriptions_user_status_idx on public.user_subscriptions(user_id, status);
create index tier_change_history_user_idx on public.tier_change_history(user_id, changed_at desc);
create index feature_usage_user_feature_idx on public.feature_usage_counters(user_id, feature_key, period_type, period_start);

-- ─── RLS ─────────────────────────────────────────────────────────────────────

alter table public.subscription_tiers enable row level security;
alter table public.tier_features enable row level security;
alter table public.user_subscriptions enable row level security;
alter table public.tier_change_history enable row level security;
alter table public.feature_usage_counters enable row level security;

-- Tiers + features: public read
create policy "tiers_public_read" on public.subscription_tiers for select using (true);
create policy "tier_features_public_read" on public.tier_features for select using (true);

-- User subscriptions: own only
create policy "user_subs_own" on public.user_subscriptions for all using (user_id = auth.uid());

-- Tier change history: own read only
create policy "tier_history_own_read" on public.tier_change_history for select using (user_id = auth.uid());

-- Feature usage: own only
create policy "feature_usage_own" on public.feature_usage_counters for all using (user_id = auth.uid());

-- ─── Seed: Tier definitions ───────────────────────────────────────────────────

insert into public.subscription_tiers (tier_key, display_name, display_name_tr, sort_order, price_try, price_usd, badge_color, badge_icon) values
  ('free',    'Free',    'Ücretsiz', 0, null,   null,  '#6b7280', '🐾'),
  ('premium', 'Premium', 'Premium',  1, 199.00, 19.99, '#7c3aed', '⭐'),
  ('pro_plus','Pro+',    'Pro+',     2, 349.00, 34.99, '#d97706', '🚀');

-- ─── Seed: Feature definitions per tier ──────────────────────────────────────
-- period_type NULL = feature is always-on (not counter-based)

-- FREE
insert into public.tier_features (tier_key, feature_key, is_enabled, limit_value, period_type, description_tr) values
  ('free', 'max_pets',                   true,  2,    'lifetime', 'Maksimum 2 pet'),
  ('free', 'vet_chat_daily',             false, 0,    'daily',    'Vet chat kapalı'),
  ('free', 'visual_assessment_monthly',  false, 0,    'monthly',  'Görsel gözlem kapalı'),
  ('free', 'breed_detection_monthly',    true,  1,    'monthly',  'Ayda 1 cins tahmini'),
  ('free', 'behavior_analysis_monthly',  false, 0,    'monthly',  'Davranış analizi kapalı'),
  ('free', 'family_members_max',         false, 0,    'lifetime', 'Aile üyesi kapalı'),
  ('free', 'share_links_max_active',     false, 0,    'lifetime', 'Paylaşım linki kapalı'),
  ('free', 'share_link_max_days',        false, 1,    null,       'Paylaşım linki kapalı'),
  ('free', 'sitter_assignments_max',     false, 0,    'lifetime', 'Pet sitter kapalı'),
  ('free', 'care_handoffs_max_active',   true,  5,    'lifetime', 'Maksimum 5 aktif görev'),
  ('free', 'emergency_contacts_max',     true,  10,   'lifetime', '10 acil kontak'),
  ('free', 'lost_pet_alerts_max',        true,  1,    'lifetime', '1 kayıp ilan'),
  ('free', 'vet_map_search',             true,  null, null,       'Vet harita arama'),
  ('free', 'pet_share_link',             false, 0,    null,       'Vet paylaşım linki kapalı');

-- PREMIUM
insert into public.tier_features (tier_key, feature_key, is_enabled, limit_value, period_type, description_tr) values
  ('premium', 'max_pets',                   true,  null, 'lifetime', 'Sınırsız pet'),
  ('premium', 'vet_chat_daily',             true,  5,    'daily',    'Günde 5 vet chat mesajı'),
  ('premium', 'visual_assessment_monthly',  true,  3,    'monthly',  'Ayda 3 görsel gözlem'),
  ('premium', 'breed_detection_monthly',    true,  5,    'monthly',  'Ayda 5 cins tahmini'),
  ('premium', 'behavior_analysis_monthly',  true,  2,    'monthly',  'Ayda 2 davranış analizi'),
  ('premium', 'family_members_max',         true,  1,    'lifetime', '1 aile üyesi'),
  ('premium', 'share_links_max_active',     true,  3,    'lifetime', '3 aktif paylaşım linki'),
  ('premium', 'share_link_max_days',        true,  7,    null,       '7 güne kadar link'),
  ('premium', 'sitter_assignments_max',     true,  1,    'lifetime', '1 aktif sitter görevi'),
  ('premium', 'care_handoffs_max_active',   true,  null, 'lifetime', 'Sınırsız görev'),
  ('premium', 'emergency_contacts_max',     true,  null, 'lifetime', 'Sınırsız acil kontak'),
  ('premium', 'lost_pet_alerts_max',        true,  3,    'lifetime', '3 kayıp ilan'),
  ('premium', 'vet_map_search',             true,  null, null,       'Vet harita arama'),
  ('premium', 'pet_share_link',             true,  null, null,       'Vet paylaşım linki');

-- PRO+
insert into public.tier_features (tier_key, feature_key, is_enabled, limit_value, period_type, description_tr) values
  ('pro_plus', 'max_pets',                   true,  null, 'lifetime', 'Sınırsız pet'),
  ('pro_plus', 'vet_chat_daily',             true,  null, 'daily',    'Sınırsız vet chat'),
  ('pro_plus', 'visual_assessment_monthly',  true,  null, 'monthly',  'Sınırsız görsel gözlem'),
  ('pro_plus', 'breed_detection_monthly',    true,  null, 'monthly',  'Sınırsız cins tahmini'),
  ('pro_plus', 'behavior_analysis_monthly',  true,  null, 'monthly',  'Sınırsız davranış analizi'),
  ('pro_plus', 'family_members_max',         true,  5,    'lifetime', '5 aile üyesi'),
  ('pro_plus', 'share_links_max_active',     true,  null, 'lifetime', 'Sınırsız paylaşım linki'),
  ('pro_plus', 'share_link_max_days',        true,  null, null,       'Süresiz link'),
  ('pro_plus', 'sitter_assignments_max',     true,  null, 'lifetime', 'Sınırsız sitter görevi'),
  ('pro_plus', 'care_handoffs_max_active',   true,  null, 'lifetime', 'Sınırsız görev'),
  ('pro_plus', 'emergency_contacts_max',     true,  null, 'lifetime', 'Sınırsız acil kontak'),
  ('pro_plus', 'lost_pet_alerts_max',        true,  null, 'lifetime', 'Sınırsız kayıp ilan'),
  ('pro_plus', 'vet_map_search',             true,  null, null,       'Vet harita arama'),
  ('pro_plus', 'pet_share_link',             true,  null, null,       'Vet paylaşım linki'),
  ('pro_plus', 'behavior_analysis_auto',     true,  null, null,       'Otomatik davranış analizi');

-- ─── Migrate existing premium users ──────────────────────────────────────────
-- Insert free subscription for all existing users (upsert on conflict)
-- Premium users from profiles.is_premium will be handled by app on first load

insert into public.user_subscriptions (user_id, tier_key, status, source)
select id, 'free', 'active', 'free'
from auth.users
on conflict (user_id) do nothing;

-- Upgrade existing premium users
update public.user_subscriptions us
set tier_key = 'premium',
    source = 'manual',
    updated_at = now()
from public.profiles p
where us.user_id = p.id
  and p.is_premium = true;
