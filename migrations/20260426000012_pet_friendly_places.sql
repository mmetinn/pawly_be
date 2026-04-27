-- Migration: pet-friendly places

-- ─── Enums ───────────────────────────────────────────────────────────────────

create type public.place_type_enum as enum (
  'cafe','restaurant','park','beach','hotel','shopping_mall',
  'pet_shop','dog_park','hiking_trail','bar','other'
);

create type public.pet_size_allowed_enum as enum (
  'small_only','medium_below','all_sizes','unknown'
);

create type public.place_status_enum as enum (
  'pending','approved','rejected','reported'
);

create type public.review_status_enum as enum (
  'visible','hidden','reported'
);

create type public.report_reason_enum as enum (
  'not_pet_friendly','closed_permanently','duplicate',
  'inappropriate','inaccurate_info','other'
);

create type public.report_status_enum as enum (
  'pending','resolved','dismissed'
);

-- ─── pet_friendly_places ─────────────────────────────────────────────────────

create table public.pet_friendly_places (
  id                   uuid              primary key default uuid_generate_v4(),
  place_id             text              unique,           -- Google Places ID (nullable for user-added)
  is_user_added        boolean           not null default false,
  name                 text              not null,
  place_type           place_type_enum   not null default 'other',
  address              text,
  city                 text              not null,
  district             text,
  latitude             numeric(10,7)     not null,
  longitude            numeric(10,7)     not null,
  phone                text,
  website              text,
  description          text,
  photo_urls           text[],

  -- Pet-friendly features
  pet_size_allowed     pet_size_allowed_enum not null default 'unknown',
  indoor_allowed       boolean,
  outdoor_only         boolean,
  leash_required       boolean,
  water_bowl_provided  boolean,
  pet_menu_available   boolean,
  off_leash_area       boolean,
  fenced               boolean,

  -- Status & moderation
  status               place_status_enum not null default 'pending',
  added_by             uuid              references auth.users(id) on delete set null,
  approved_by          uuid              references auth.users(id) on delete set null,
  approved_at          timestamptz,
  rejection_reason     text,

  -- Stats
  average_rating       numeric(2,1),
  review_count         int               not null default 0,
  last_verified_at     timestamptz,

  created_at           timestamptz       not null default now(),
  updated_at           timestamptz       not null default now()
);

alter table public.pet_friendly_places enable row level security;

create policy "places_select_approved" on public.pet_friendly_places
  for select using (status = 'approved');

create policy "places_insert_own" on public.pet_friendly_places
  for insert with check (auth.uid() = added_by);

create policy "places_update_own_pending" on public.pet_friendly_places
  for update using (auth.uid() = added_by and status = 'pending');

create index idx_places_city_status_type
  on public.pet_friendly_places(city, status, place_type);

create index idx_places_latlong
  on public.pet_friendly_places(latitude, longitude);

-- ─── place_reviews ───────────────────────────────────────────────────────────

create table public.place_reviews (
  id           uuid              primary key default uuid_generate_v4(),
  place_id     uuid              not null references public.pet_friendly_places(id) on delete cascade,
  user_id      uuid              not null references auth.users(id) on delete cascade,
  pet_id       uuid              references public.pets(id) on delete set null,
  rating       int               not null check (rating between 1 and 5),
  review_text  text,
  visit_date   date,
  photo_urls   text[],
  status       review_status_enum not null default 'visible',
  helpful_count int              not null default 0,
  created_at   timestamptz       not null default now(),
  updated_at   timestamptz       not null default now(),
  unique(place_id, user_id)
);

alter table public.place_reviews enable row level security;

create policy "reviews_select_visible" on public.place_reviews
  for select using (status = 'visible');

create policy "reviews_insert_own" on public.place_reviews
  for insert with check (auth.uid() = user_id);

create policy "reviews_update_own" on public.place_reviews
  for update using (auth.uid() = user_id);

create policy "reviews_delete_own" on public.place_reviews
  for delete using (auth.uid() = user_id);

create index idx_reviews_place_status_date
  on public.place_reviews(place_id, status, created_at desc);

-- ─── place_reports ───────────────────────────────────────────────────────────

create table public.place_reports (
  id          uuid              primary key default uuid_generate_v4(),
  place_id    uuid              not null references public.pet_friendly_places(id) on delete cascade,
  reported_by uuid              not null references auth.users(id) on delete cascade,
  reason      report_reason_enum not null,
  description text,
  status      report_status_enum not null default 'pending',
  created_at  timestamptz       not null default now()
);

alter table public.place_reports enable row level security;

create policy "reports_insert_own" on public.place_reports
  for insert with check (auth.uid() = reported_by);

create policy "reports_select_own" on public.place_reports
  for select using (auth.uid() = reported_by);

-- ─── place_favorites ─────────────────────────────────────────────────────────

create table public.place_favorites (
  id             uuid        primary key default uuid_generate_v4(),
  user_id        uuid        not null references auth.users(id) on delete cascade,
  place_id       uuid        not null references public.pet_friendly_places(id) on delete cascade,
  personal_notes text,
  created_at     timestamptz not null default now(),
  unique(user_id, place_id)
);

alter table public.place_favorites enable row level security;

create policy "favorites_all_own" on public.place_favorites
  for all using (auth.uid() = user_id);

create index idx_favorites_user on public.place_favorites(user_id);

-- ─── Seed: approved pet-friendly places (TR major cities) ────────────────────
-- Coordinates are approximate. status=approved, is_user_added=false, last_verified_at=NULL

insert into public.pet_friendly_places
  (name, place_type, address, city, district, latitude, longitude,
   pet_size_allowed, indoor_allowed, outdoor_only, water_bowl_provided,
   status, is_user_added, description)
values
-- İstanbul – Kadıköy / Moda / Beşiktaş / Nişantaşı
('Moda Çayı', 'cafe', 'Moda Cad. Kadıköy', 'İstanbul', 'Kadıköy',
 40.9867, 29.0280, 'all_sizes', true, false, true, 'approved', false,
 'Köpeklerin rahatça girebileceği bahçeli kafe, su kabı servis ediliyor.'),

('Karga Bar & Cafe', 'cafe', 'Kadife Sok. 16 Kadıköy', 'İstanbul', 'Kadıköy',
 40.9841, 29.0302, 'all_sizes', true, false, true, 'approved', false,
 'Sokak hayvanlarına dost, köpekler içeri kabul ediliyor.'),

('Bosphorus Coffee Beşiktaş', 'cafe', 'Sinanpaşa Mah. Beşiktaş', 'İstanbul', 'Beşiktaş',
 41.0433, 29.0058, 'small_only', true, false, true, 'approved', false,
 'Küçük ırk köpekler içeri alınıyor, büyükler bahçede.'),

('Fenerbahçe Parkı', 'park', 'Fenerbahçe Parkı Kadıköy', 'İstanbul', 'Kadıköy',
 40.9650, 29.0430, 'all_sizes', false, true, false, 'approved', false,
 'Geniş sahil parkı, tasma ile tüm köpekler serbest.'),

('Bebek Sahili', 'park', 'Bebek Sahil Yolu Beşiktaş', 'İstanbul', 'Beşiktaş',
 41.0765, 29.0433, 'all_sizes', false, true, false, 'approved', false,
 'Sabah erken saatlerde köpekler tasmasız koşturabilir.'),

('Koton Café Nişantaşı', 'cafe', 'Abdi İpekçi Cad. Nişantaşı', 'İstanbul', 'Şişli',
 41.0480, 28.9951, 'small_only', true, false, true, 'approved', false,
 'Butik kafe, küçük köpekler sepet/çantada kabul ediliyor.'),

('Emirgan Korusu', 'park', 'Emirgan Korusu Sarıyer', 'İstanbul', 'Sarıyer',
 41.1082, 29.0542, 'all_sizes', false, true, false, 'approved', false,
 'Büyük orman parkı, köpekler için ideal yürüyüş alanı.'),

('The Dog Bar Karaköy', 'bar', 'Kemankeş Mah. Karaköy', 'İstanbul', 'Beyoğlu',
 41.0228, 28.9767, 'all_sizes', true, false, true, 'approved', false,
 'Köpek dostu bar, hafta sonu köpek buluşmaları düzenleniyor.'),

('Arnavutköy Sahili', 'park', 'Arnavutköy Beşiktaş', 'İstanbul', 'Beşiktaş',
 41.0598, 29.0319, 'all_sizes', false, true, false, 'approved', false,
 'Köy sahili, balıkçı kafeler köpekleri bahçede kabul ediyor.'),

('Yıldız Parkı', 'park', 'Yıldız Parkı Beşiktaş', 'İstanbul', 'Beşiktaş',
 41.0510, 29.0112, 'all_sizes', false, true, false, 'approved', false,
 'Tarihi park, sabah yürüyüşleri için popüler köpek alanı.'),

('Cihangir Parkı Café', 'cafe', 'Cihangir Mah. Beyoğlu', 'İstanbul', 'Beyoğlu',
 41.0312, 28.9855, 'all_sizes', false, true, true, 'approved', false,
 'Parka bakan terası olan kafe, köpekler dışarıda hoş karşılanıyor.'),

('Maçka Demokrasi Parkı', 'dog_park', 'Maçka Parkı Beşiktaş', 'İstanbul', 'Beşiktaş',
 41.0446, 28.9987, 'all_sizes', false, true, false, 'approved', false,
 'Çevrili köpek koşturma alanı, sabah 7-9 tasmasız serbest.'),

-- Ankara – Tunalı / Çankaya / Kızılay
('Turuncu Cafe Tunalı', 'cafe', 'Tunalı Hilmi Cad. Çankaya', 'Ankara', 'Çankaya',
 39.9030, 32.8626, 'all_sizes', true, false, true, 'approved', false,
 'Bahçeli kafe, köpekler için su ve atıştırmalık ikram ediliyor.'),

('Segah Kafe Tunalı', 'cafe', 'Bülten Sok. Kavaklıdere', 'Ankara', 'Çankaya',
 39.9016, 32.8637, 'medium_below', true, false, true, 'approved', false,
 'Orta boy ve küçük köpekler bahçede kabul ediliyor.'),

('Gençlik Parkı', 'park', 'Ulus Gençlik Parkı Altındağ', 'Ankara', 'Altındağ',
 39.9333, 32.8499, 'all_sizes', false, true, false, 'approved', false,
 'Büyük şehir parkı, gölette yürüyüş köpeklerle popüler.'),

('Kugulu Park', 'park', 'Kavaklıdere Kuğulu Park Çankaya', 'Ankara', 'Çankaya',
 39.9002, 32.8616, 'all_sizes', false, true, true, 'approved', false,
 'Şehir merkezinde küçük park, köpek sahipleri için buluşma noktası.'),

('Cafe Crown Çankaya', 'cafe', 'Arjantin Cad. Çankaya', 'Ankara', 'Çankaya',
 39.8981, 32.8608, 'small_only', true, false, true, 'approved', false,
 'Küçük ırklar içeri alınıyor, tüm ırklar terasta hoş karşılanıyor.'),

('Eymir Gölü', 'hiking_trail', 'Eymir Gölü ODTÜ Güney', 'Ankara', 'Gölbaşı',
 39.8401, 32.7867, 'all_sizes', false, true, false, 'approved', false,
 'ODTÜ ormanı içinde göl çevresi yürüyüş yolu, köpekler için cennet.'),

-- İzmir – Kordon / Alsancak / Bornova
('Kordon Cafe İzmir', 'cafe', 'Birinci Kordon Konak', 'İzmir', 'Konak',
 38.4250, 27.1392, 'all_sizes', false, true, true, 'approved', false,
 'Deniz kenarı kafe, köpekler açık alanda servisle ağırlanıyor.'),

('Alsancak Coffee Lab', 'cafe', 'Kıbrıs Şehitleri Cad. Alsancak', 'İzmir', 'Konak',
 38.4389, 27.1443, 'all_sizes', true, false, true, 'approved', false,
 'Köpeksever barista ekibi, her boyut köpek kabul ediliyor.'),

('Bornova Gençlik Parkı', 'park', 'Bornova Merkez Park', 'İzmir', 'Bornova',
 38.4665, 27.2218, 'all_sizes', false, true, false, 'approved', false,
 'Geniş yeşil alan, sabah yürüyüşleri köpeklerle popüler.'),

('Balçova Köpek Parkı', 'dog_park', 'Balçova Belediye Köpek Parkı', 'İzmir', 'Balçova',
 38.3882, 27.0450, 'all_sizes', false, true, false, 'approved', false,
 'Belediye tarafından kurulmuş çevrili köpek oyun alanı, su havuzu var.'),

('Çeşme İlica Plajı', 'beach', 'İlica Plajı Çeşme', 'İzmir', 'Çeşme',
 38.3252, 26.3826, 'all_sizes', false, true, false, 'approved', false,
 'Sabah erken ve akşam geç saatlerde köpekler plaja girebilir.'),

('Cafe Fika Alsancak', 'cafe', 'Halit Ziya Bulv. Alsancak', 'İzmir', 'Konak',
 38.4345, 27.1478, 'medium_below', true, false, true, 'approved', false,
 'Kahve kültürü odaklı kafe, orta ve küçük köpekler içeri alınıyor.'),

-- Antalya – Kaleiçi / Konyaaltı / Lara
('Kaleiçi Marina Cafe', 'cafe', 'Kaleiçi Yat Limanı Muratpaşa', 'Antalya', 'Muratpaşa',
 36.8840, 30.7050, 'all_sizes', false, true, true, 'approved', false,
 'Marina kenarı kafe, denize bakan teraslarda tüm köpekler hoş karşılanıyor.'),

('Konyaaltı Sahil Parkı', 'park', 'Konyaaltı Sahili Kepez', 'Antalya', 'Kepez',
 36.8798, 30.6421, 'all_sizes', false, true, false, 'approved', false,
 'Uzun sahil bandı, sabah ve akşam köpek yürüyüşleri için ideal.'),

('Güver Kanyonu', 'hiking_trail', 'Güver Uçurumu Kepez', 'Antalya', 'Kepez',
 37.0432, 30.6789, 'all_sizes', false, true, false, 'approved', false,
 'Kanyona bakan yürüyüş parkuru, köpekler tasma ile serbestçe dolaşabilir.'),

('Botanik Park Cafe', 'cafe', 'Atatürk Kültür Parkı Muratpaşa', 'Antalya', 'Muratpaşa',
 36.8883, 30.6988, 'all_sizes', false, true, true, 'approved', false,
 'Kültür parkı içindeki kafe, bahçede tüm köpekler için yer var.'),

('Lara Beach Club', 'beach', 'Lara Plajı Aksu', 'Antalya', 'Aksu',
 36.8478, 30.8456, 'all_sizes', false, true, false, 'approved', false,
 'Sezon dışı (Ekim-Nisan) köpekler plaja kabul ediliyor.'),

('Kalekapısı Pastanesi', 'cafe', 'Kaleiçi Kalekapısı Muratpaşa', 'Antalya', 'Muratpaşa',
 36.8867, 30.7063, 'small_only', true, false, true, 'approved', false,
 'Tarihi konakta kafe, küçük köpekler içeri alınıyor.'),

('Old Town Pub Kaleiçi', 'bar', 'Hesapçı Sok. Kaleiçi Muratpaşa', 'Antalya', 'Muratpaşa',
 36.8845, 30.7057, 'all_sizes', false, true, false, 'approved', false,
 'Tarihi çarşı içinde bahçeli pub, akşamları köpek sahiplerinin buluşma noktası.');
