-- Emergency Contacts: acil durum kontak listesi
-- Migration: 000022

create type public.emergency_contact_type as enum (
  'primary_vet', 'backup_vet', 'emergency_vet',
  'poison_control', 'pet_sitter', 'family_member',
  'neighbor', 'transporter', 'specialist',
  'shelter', 'animal_control', 'other'
);

create table public.emergency_contacts (
  id                    uuid primary key default gen_random_uuid(),
  user_id               uuid not null references auth.users(id) on delete cascade,
  pet_id                uuid references public.pets(id) on delete cascade,
  contact_type          public.emergency_contact_type not null default 'other',
  name                  text not null,
  phone                 text not null,
  alternative_phone     text,
  whatsapp              text,
  email                 text,
  address               text,
  latitude              numeric(10,7),
  longitude             numeric(10,7),
  notes                 text,
  is_primary            boolean not null default false,
  sort_order            int not null default 0,
  linked_place_id       text,
  linked_pet_member_id  uuid references public.pet_members(id) on delete set null,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);

create index emergency_contacts_user_type_idx on public.emergency_contacts(user_id, contact_type);
create index emergency_contacts_user_primary_idx on public.emergency_contacts(user_id, is_primary) where is_primary = true;
create index emergency_contacts_pet_idx on public.emergency_contacts(pet_id) where pet_id is not null;

alter table public.emergency_contacts enable row level security;

create policy "emergency_contacts_own" on public.emergency_contacts
  for all using (user_id = auth.uid());
