import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

function secureToken(): string {
  const bytes = new Uint8Array(24);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, b => b.toString(16).padStart(2, "0")).join("");
}

// ─── Route: POST / — Create share link ───────────────────────────────────────
async function handleCreate(req: Request): Promise<Response> {
  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return new Response("Unauthorized", { status: 401 });

  const userClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: { user }, error: authError } = await userClient.auth.getUser();
  if (authError || !user) return new Response("Unauthorized", { status: 401 });

  const svc = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY);

  // Rate limit: 10 links per hour
  const hourAgo = new Date(Date.now() - 3_600_000).toISOString();
  const { count: recentCount } = await svc
    .from("pet_share_links")
    .select("id", { count: "exact", head: true })
    .eq("created_by", user.id)
    .gte("created_at", hourAgo);

  if ((recentCount ?? 0) >= 10) {
    return new Response(JSON.stringify({ error: "RATE_LIMIT" }), {
      status: 429, headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  const body = await req.json();
  const {
    pet_id,
    share_type = "full_record",
    included_sections,
    date_range_start,
    date_range_end,
    recipient_name,
    recipient_email,
    access_passcode,
    expires_in_hours = 168,
    max_views,
  } = body;

  if (!pet_id) {
    return new Response(JSON.stringify({ error: "pet_id required" }), {
      status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  // Verify user has owner/co_owner access
  const { data: member } = await svc
    .from("pet_members")
    .select("role")
    .eq("pet_id", pet_id)
    .eq("user_id", user.id)
    .eq("status", "active")
    .in("role", ["owner", "co_owner"])
    .maybeSingle();

  if (!member) {
    return new Response(JSON.stringify({ error: "FORBIDDEN" }), {
      status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  const token = secureToken();
  const expiresAt = new Date(Date.now() + expires_in_hours * 3_600_000).toISOString();

  // Default sections by share_type
  let sections = included_sections;
  if (!sections) {
    if (share_type === "vaccination_only") {
      sections = { basic_info: true, vaccinations: true, medications: false, vet_visits: false, surgeries: false, weight_history: false, parasites: false, feeding: false, exercise: false, photos: false };
    } else if (share_type === "emergency_summary") {
      sections = { basic_info: true, vaccinations: false, medications: true, vet_visits: false, surgeries: false, weight_history: true, parasites: false, feeding: true, exercise: false, photos: true };
    } else {
      sections = { basic_info: true, vaccinations: true, medications: true, vet_visits: true, surgeries: true, weight_history: true, parasites: true, feeding: false, exercise: false, photos: true };
    }
  }

  const { data, error } = await svc
    .from("pet_share_links")
    .insert({
      pet_id,
      created_by: user.id,
      share_token: token,
      share_type,
      included_sections: sections,
      date_range_start: date_range_start ?? null,
      date_range_end: date_range_end ?? null,
      recipient_name: recipient_name ?? null,
      recipient_email: recipient_email ?? null,
      access_passcode: access_passcode ?? null,
      expires_at: expiresAt,
      max_views: max_views ?? null,
    })
    .select()
    .single();

  if (error) {
    return new Response(JSON.stringify({ error: error.message }), {
      status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  return new Response(JSON.stringify(data), {
    status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

// ─── Route: GET /shared/{token} — Web view ────────────────────────────────────
async function handleWebView(token: string, req: Request): Promise<Response> {
  const svc = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY);
  const url = new URL(req.url);
  const passcode = url.searchParams.get("passcode") ?? req.headers.get("x-share-passcode");

  // Fetch share link
  const { data: link } = await svc
    .from("pet_share_links")
    .select("*")
    .eq("share_token", token)
    .eq("is_active", true)
    .maybeSingle();

  if (!link) return htmlError("Bu bağlantı geçersiz veya iptal edilmiş.", "Link Not Found");

  // Check expiry
  if (new Date(link.expires_at) < new Date()) {
    await svc.from("pet_share_links").update({ is_active: false }).eq("id", link.id);
    return htmlError("Bu bağlantının süresi dolmuş.", "Link Expired");
  }

  // Check max views
  if (link.max_views != null && link.view_count >= link.max_views) {
    return htmlError("Bu bağlantının görüntüleme limiti dolmuş.", "View Limit Reached");
  }

  // Passcode check
  if (link.access_passcode) {
    const ip = req.headers.get("x-forwarded-for") ?? "unknown";
    if (!passcode) {
      // Check failed attempts in last hour
      const { count: failedAttempts } = await svc
        .from("share_link_views")
        .select("id", { count: "exact", head: true })
        .eq("share_link_id", link.id)
        .eq("is_passcode_attempt", true)
        .eq("passcode_correct", false)
        .gte("viewed_at", new Date(Date.now() - 3_600_000).toISOString());

      if ((failedAttempts ?? 0) >= 3) {
        return htmlPasscodeForm(token, true);
      }
      return htmlPasscodeForm(token, false);
    }

    const correct = passcode === link.access_passcode;
    await svc.from("share_link_views").insert({
      share_link_id: link.id,
      ip_address: ip,
      user_agent: req.headers.get("user-agent"),
      is_passcode_attempt: true,
      passcode_correct: correct,
    });
    if (!correct) return htmlPasscodeForm(token, false, true);
  }

  // Fetch pet data
  const sections = link.included_sections as Record<string, boolean>;
  const pet = await fetchPetData(svc, link.pet_id, sections, link.date_range_start, link.date_range_end);

  // Log view
  const ip = req.headers.get("x-forwarded-for") ?? "unknown";
  await svc.from("share_link_views").insert({
    share_link_id: link.id,
    ip_address: ip,
    user_agent: req.headers.get("user-agent"),
    is_passcode_attempt: false,
    passcode_correct: null,
  });

  await svc.from("pet_share_links").update({
    view_count: (link.view_count ?? 0) + 1,
    last_viewed_at: new Date().toISOString(),
    last_viewed_ip: ip,
  }).eq("id", link.id);

  return new Response(renderPetPage(pet, link, sections), {
    status: 200,
    headers: { "Content-Type": "text/html; charset=utf-8" },
  });
}

// ─── Fetch all pet data ────────────────────────────────────────────────────────
async function fetchPetData(
  svc: ReturnType<typeof createClient>,
  petId: string,
  sections: Record<string, boolean>,
  dateStart?: string | null,
  dateEnd?: string | null
): Promise<Record<string, unknown>> {
  const dateFilter = (query: unknown) => {
    let q = query as { gte: (col: string, val: string) => unknown; lte: (col: string, val: string) => unknown };
    if (dateStart) q = q.gte("date", dateStart) as typeof q;
    if (dateEnd) q = q.lte("date", dateEnd) as typeof q;
    return q;
  };

  const [petRes, vaccRes, medRes, vetRes, surgRes, weightRes, paraRes, feedRes] = await Promise.all([
    svc.from("pets").select("*").eq("id", petId).single(),
    sections.vaccinations ? svc.from("vaccinations").select("*").eq("pet_id", petId).order("date", { ascending: false }) : Promise.resolve({ data: [] }),
    sections.medications ? svc.from("medications").select("*").eq("pet_id", petId).eq("is_active", true) : Promise.resolve({ data: [] }),
    sections.vet_visits ? svc.from("vet_visits").select("*").eq("pet_id", petId).order("date", { ascending: false }).limit(50) : Promise.resolve({ data: [] }),
    sections.surgeries ? svc.from("surgeries").select("*").eq("pet_id", petId).order("date", { ascending: false }) : Promise.resolve({ data: [] }),
    sections.weight_history ? svc.from("weight_logs").select("*").eq("pet_id", petId).order("date", { ascending: false }).limit(24) : Promise.resolve({ data: [] }),
    sections.parasites ? svc.from("parasite_preventions").select("*").eq("pet_id", petId).order("date", { ascending: false }) : Promise.resolve({ data: [] }),
    sections.feeding ? svc.from("feeding_schedules").select("*").eq("pet_id", petId).eq("is_active", true) : Promise.resolve({ data: [] }),
  ]);

  return {
    pet: petRes.data,
    vaccinations: vaccRes.data ?? [],
    medications: medRes.data ?? [],
    vet_visits: vetRes.data ?? [],
    surgeries: surgRes.data ?? [],
    weight_logs: weightRes.data ?? [],
    parasites: paraRes.data ?? [],
    feeding: feedRes.data ?? [],
  };
}

// ─── HTML renderers ───────────────────────────────────────────────────────────
function htmlError(message: string, title: string): Response {
  return new Response(`<!DOCTYPE html><html lang="tr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Pawly — ${title}</title><style>body{font-family:system-ui,sans-serif;display:flex;align-items:center;justify-content:center;min-height:100vh;margin:0;background:#f9fafb;}.card{background:#fff;border-radius:16px;padding:48px 32px;text-align:center;box-shadow:0 4px 24px rgba(0,0,0,.08);max-width:400px;width:90%;}h1{color:#dc2626;font-size:1.5rem;}p{color:#6b7280;margin-top:8px;}.logo{font-size:2rem;margin-bottom:16px;}</style></head><body><div class="card"><div class="logo">🐾</div><h1>Hata</h1><p>${message}</p><p style="margin-top:24px;font-size:.85rem;color:#9ca3af;">Bağlantıyı size gönderen kişiyle iletişime geçin.</p></div></body></html>`, {
    status: 410,
    headers: { "Content-Type": "text/html; charset=utf-8" },
  });
}

function htmlPasscodeForm(token: string, locked: boolean, incorrect = false): Response {
  const html = `<!DOCTYPE html>
<html lang="tr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Pawly — Şifreli Bağlantı</title>
<style>
*{box-sizing:border-box}body{font-family:system-ui,sans-serif;display:flex;align-items:center;justify-content:center;min-height:100vh;margin:0;background:#f5f3ff;}
.card{background:#fff;border-radius:16px;padding:40px 32px;text-align:center;box-shadow:0 4px 24px rgba(0,0,0,.08);max-width:380px;width:90%;}
.logo{font-size:2.5rem;margin-bottom:8px;}.title{font-size:1.25rem;font-weight:700;color:#1f2937;margin:0 0 8px;}
.sub{color:#6b7280;font-size:.9rem;margin-bottom:24px;}
input{width:100%;border:2px solid ${incorrect ? "#dc2626" : "#e5e7eb"};border-radius:12px;padding:14px 16px;font-size:1.5rem;text-align:center;letter-spacing:8px;outline:none;transition:border-color .2s;}
input:focus{border-color:#7c3aed;}
.err{color:#dc2626;font-size:.85rem;margin-top:8px;}
button{width:100%;background:#7c3aed;color:#fff;border:none;border-radius:12px;padding:14px;font-size:1rem;font-weight:600;cursor:pointer;margin-top:16px;transition:background .2s;}
button:hover{background:#6d28d9;}
.lock{font-size:1.5rem;color:#dc2626;margin-bottom:8px;}
</style></head><body>
<div class="card">
  <div class="logo">🐾</div>
  ${locked
    ? `<div class="lock">🔒</div><p class="title">Erişim Geçici Olarak Kilitli</p><p class="sub">Çok fazla hatalı deneme. 1 saat sonra tekrar deneyin.</p>`
    : `<p class="title">Şifreli Bağlantı</p>
       <p class="sub">Bu bağlantıya erişmek için 4 haneli kodu girin.</p>
       <form method="GET" action="/functions/v1/share-pet-record/shared/${token}">
         <input type="text" name="passcode" maxlength="4" pattern="[0-9]{4}" placeholder="••••" autocomplete="off" autofocus inputmode="numeric">
         ${incorrect ? '<p class="err">Hatalı kod. Lütfen tekrar deneyin.</p>' : ""}
         <button type="submit">Devam Et →</button>
       </form>`
  }
</div></body></html>`;
  return new Response(html, { status: 200, headers: { "Content-Type": "text/html; charset=utf-8" } });
}

function renderPetPage(data: Record<string, unknown>, link: Record<string, unknown>, sections: Record<string, boolean>): string {
  const pet = data.pet as Record<string, unknown>;
  const vaccinations = data.vaccinations as Record<string, unknown>[];
  const medications = data.medications as Record<string, unknown>[];
  const vet_visits = data.vet_visits as Record<string, unknown>[];
  const surgeries = data.surgeries as Record<string, unknown>[];
  const weight_logs = data.weight_logs as Record<string, unknown>[];
  const parasites = data.parasites as Record<string, unknown>[];
  const feeding = data.feeding as Record<string, unknown>[];

  const speciesEmoji = pet?.species === "dog" ? "🐕" : pet?.species === "cat" ? "🐈" : "🐾";
  const age = pet?.birth_date ? calcAge(String(pet.birth_date)) : null;
  const latestWeight = weight_logs.length > 0 ? weight_logs[0] : null;

  const fmt = (date: string) => new Date(date).toLocaleDateString("tr-TR");

  const vaccinationRows = vaccinations.map(v =>
    `<tr><td>${String(v.vaccine_name ?? "")}</td><td>${v.date ? fmt(String(v.date)) : "—"}</td><td>${v.next_due_date ? fmt(String(v.next_due_date)) : "—"}</td><td>${String(v.notes ?? "")}</td></tr>`
  ).join("");

  const medicationRows = medications.map(m =>
    `<tr><td>${String(m.name ?? "")}</td><td>${String(m.dosage ?? "")}</td><td>${String(m.frequency ?? "")}</td><td>${m.end_date ? fmt(String(m.end_date)) : "Süresiz"}</td></tr>`
  ).join("");

  const vetRows = vet_visits.map(v =>
    `<tr><td>${v.date ? fmt(String(v.date)) : "—"}</td><td>${String(v.reason ?? "")}</td><td>${String(v.diagnosis ?? "")}</td><td>${String(v.clinic_name ?? "")}</td></tr>`
  ).join("");

  const surgeryRows = surgeries.map(s =>
    `<tr><td>${s.date ? fmt(String(s.date)) : "—"}</td><td>${String(s.procedure_name ?? "")}</td><td>${String(s.clinic_name ?? "")}</td><td>${String(s.notes ?? "")}</td></tr>`
  ).join("");

  const parasiteRows = parasites.map(p =>
    `<tr><td>${String(p.product_name ?? "")}</td><td>${String(p.type ?? "")}</td><td>${p.date ? fmt(String(p.date)) : "—"}</td><td>${p.next_due_date ? fmt(String(p.next_due_date)) : "—"}</td></tr>`
  ).join("");

  return `<!DOCTYPE html>
<html lang="tr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${String(pet?.name ?? "Pet")} — Pawly Tıbbi Kayıt</title>
<style>
*{box-sizing:border-box}
body{font-family:system-ui,-apple-system,sans-serif;margin:0;background:#f9fafb;color:#1f2937;}
.container{max-width:800px;margin:0 auto;padding:16px;}
.header{background:linear-gradient(135deg,#7c3aed,#a855f7);color:#fff;border-radius:16px;padding:24px;margin-bottom:16px;display:flex;align-items:center;gap:16px;}
.pet-emoji{font-size:56px;}
.pet-info h1{font-size:1.75rem;margin:0 0 4px;font-weight:800;}
.pet-info .meta{font-size:.9rem;opacity:.85;line-height:1.8;}
.badge{display:inline-block;background:rgba(255,255,255,.2);border-radius:20px;padding:2px 10px;font-size:.8rem;margin:0 4px;}
.section{background:#fff;border-radius:12px;padding:20px;margin-bottom:12px;box-shadow:0 1px 4px rgba(0,0,0,.06);}
.section-title{font-size:1rem;font-weight:700;color:#374151;margin:0 0 12px;display:flex;align-items:center;gap:8px;}
.section-title span{font-size:1.25rem;}
table{width:100%;border-collapse:collapse;font-size:.875rem;}
thead tr{background:#f3f4f6;}
th{text-align:left;padding:8px 10px;font-weight:600;color:#6b7280;font-size:.8rem;text-transform:uppercase;letter-spacing:.03em;}
td{padding:8px 10px;border-bottom:1px solid #f3f4f6;color:#374151;}
tr:last-child td{border-bottom:none;}
.weight-chip{display:inline-flex;align-items:center;background:#ede9fe;color:#7c3aed;font-weight:700;padding:6px 14px;border-radius:20px;font-size:1.1rem;}
.empty{color:#9ca3af;font-size:.875rem;font-style:italic;}
.info-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(180px,1fr));gap:12px;}
.info-item{background:#f9fafb;border-radius:8px;padding:10px 14px;}
.info-item .label{font-size:.75rem;color:#9ca3af;text-transform:uppercase;font-weight:600;margin-bottom:2px;}
.info-item .value{font-size:.9rem;font-weight:600;color:#1f2937;}
.footer{text-align:center;padding:24px 16px;color:#9ca3af;font-size:.8rem;}
.footer .powered{font-weight:700;color:#7c3aed;}
.print-btn{display:block;width:100%;background:#7c3aed;color:#fff;border:none;border-radius:12px;padding:14px;font-size:1rem;font-weight:600;cursor:pointer;margin-bottom:12px;}
.expires-note{font-size:.8rem;color:#d97706;text-align:center;margin-bottom:12px;}
@media print{.print-btn,.expires-note{display:none!important;}.header{-webkit-print-color-adjust:exact;print-color-adjust:exact;}.section{break-inside:avoid;}}
@media(max-width:600px){.header{flex-direction:column;text-align:center;}.pet-emoji{font-size:72px;}.info-grid{grid-template-columns:1fr 1fr;}}
</style>
</head>
<body>
<div class="container">

<button class="print-btn" onclick="window.print()">🖨️ Yazdır / PDF Olarak İndir</button>
<p class="expires-note">⏰ Bu bağlantı ${fmt(String(link.expires_at))} tarihinde sona erecek</p>

<!-- Header -->
<div class="header">
  <div class="pet-emoji">${speciesEmoji}</div>
  <div class="pet-info">
    <h1>${String(pet?.name ?? "Pet")}</h1>
    <div class="meta">
      ${pet?.breed ? `<span class="badge">${String(pet.breed)}</span>` : ""}
      ${pet?.gender ? `<span class="badge">${String(pet.gender) === "male" ? "Erkek" : "Dişi"}</span>` : ""}
      ${age ? `<span class="badge">${age}</span>` : ""}
      ${latestWeight ? `<span class="badge">${String((latestWeight as Record<string,unknown>).weight)} kg</span>` : ""}
    </div>
  </div>
</div>

${sections.basic_info ? `
<!-- Basic Info -->
<div class="section">
  <div class="section-title"><span>📋</span> Temel Bilgiler</div>
  <div class="info-grid">
    ${pet?.birth_date ? `<div class="info-item"><div class="label">Doğum Tarihi</div><div class="value">${fmt(String(pet.birth_date))}</div></div>` : ""}
    ${pet?.species ? `<div class="info-item"><div class="label">Tür</div><div class="value">${String(pet.species) === "dog" ? "Köpek" : String(pet.species) === "cat" ? "Kedi" : String(pet.species)}</div></div>` : ""}
    ${pet?.breed ? `<div class="info-item"><div class="label">Irk</div><div class="value">${String(pet.breed)}</div></div>` : ""}
    ${pet?.gender ? `<div class="info-item"><div class="label">Cinsiyet</div><div class="value">${String(pet.gender) === "male" ? "Erkek" : "Dişi"}</div></div>` : ""}
    ${pet?.color ? `<div class="info-item"><div class="label">Renk</div><div class="value">${String(pet.color)}</div></div>` : ""}
    ${pet?.microchip_id ? `<div class="info-item"><div class="label">Mikroçip</div><div class="value" style="font-family:monospace">${String(pet.microchip_id)}</div></div>` : ""}
    ${pet?.neutered ? `<div class="info-item"><div class="label">Kısırlaştırma</div><div class="value">✅ Kısırlaştırıldı</div></div>` : ""}
    ${latestWeight ? `<div class="info-item"><div class="label">Son Kilo</div><div class="value"><span class="weight-chip">⚖️ ${String((latestWeight as Record<string,unknown>).weight)} kg</span></div></div>` : ""}
  </div>
</div>
` : ""}

${sections.vaccinations && vaccinations.length > 0 ? `
<div class="section">
  <div class="section-title"><span>💉</span> Aşılar</div>
  <table>
    <thead><tr><th>Aşı</th><th>Tarih</th><th>Sonraki</th><th>Notlar</th></tr></thead>
    <tbody>${vaccinationRows}</tbody>
  </table>
</div>
` : ""}

${sections.medications && medications.length > 0 ? `
<div class="section">
  <div class="section-title"><span>💊</span> Aktif İlaçlar</div>
  <table>
    <thead><tr><th>İlaç</th><th>Doz</th><th>Sıklık</th><th>Bitiş</th></tr></thead>
    <tbody>${medicationRows}</tbody>
  </table>
</div>
` : ""}

${sections.vet_visits && vet_visits.length > 0 ? `
<div class="section">
  <div class="section-title"><span>🏥</span> Veteriner Ziyaretleri</div>
  <table>
    <thead><tr><th>Tarih</th><th>Sebep</th><th>Tanı</th><th>Klinik</th></tr></thead>
    <tbody>${vetRows}</tbody>
  </table>
</div>
` : ""}

${sections.surgeries && surgeries.length > 0 ? `
<div class="section">
  <div class="section-title"><span>⚕️</span> Operasyonlar</div>
  <table>
    <thead><tr><th>Tarih</th><th>İşlem</th><th>Klinik</th><th>Notlar</th></tr></thead>
    <tbody>${surgeryRows}</tbody>
  </table>
</div>
` : ""}

${sections.parasites && parasites.length > 0 ? `
<div class="section">
  <div class="section-title"><span>🐛</span> Parazit Koruması</div>
  <table>
    <thead><tr><th>Ürün</th><th>Tür</th><th>Uygulama</th><th>Sonraki</th></tr></thead>
    <tbody>${parasiteRows}</tbody>
  </table>
</div>
` : ""}

${sections.weight_history && weight_logs.length > 1 ? `
<div class="section">
  <div class="section-title"><span>📈</span> Kilo Geçmişi</div>
  <table>
    <thead><tr><th>Tarih</th><th>Kilo (kg)</th><th>Notlar</th></tr></thead>
    <tbody>${weight_logs.map(w => `<tr><td>${fmt(String((w as Record<string,unknown>).date))}</td><td>${String((w as Record<string,unknown>).weight)}</td><td>${String((w as Record<string,unknown>).notes ?? "")}</td></tr>`).join("")}</tbody>
  </table>
</div>
` : ""}

${sections.feeding && feeding.length > 0 ? `
<div class="section">
  <div class="section-title"><span>🍽️</span> Beslenme</div>
  <table>
    <thead><tr><th>Mama Adı</th><th>Porsiyon</th><th>Frekans</th></tr></thead>
    <tbody>${feeding.map(f => `<tr><td>${String((f as Record<string,unknown>).food_name ?? "")}</td><td>${String((f as Record<string,unknown>).portion_size ?? "")} ${String((f as Record<string,unknown>).portion_unit ?? "")}</td><td>${String((f as Record<string,unknown>).frequency ?? "")}</td></tr>`).join("")}</tbody>
  </table>
</div>
` : ""}

<div class="footer">
  ${link.recipient_name ? `<p>Sayın <strong>${String(link.recipient_name)}</strong>, ${String(pet?.name ?? "Pet")}'in tıbbi kayıtlarını incelediğiniz için teşekkürler.</p>` : ""}
  <p>Bu kayıt <span class="powered">Pawly</span> uygulaması aracılığıyla paylaşılmıştır.</p>
  <p style="font-size:.75rem;color:#d1d5db;margin-top:4px;">Bu belge anlık bir veri özetidir. Güncel bilgiler için lütfen pet sahibiyle iletişime geçin.</p>
</div>

</div>
</body>
</html>`;
}

function calcAge(birthDate: string): string {
  const birth = new Date(birthDate);
  const now = new Date();
  const months = (now.getFullYear() - birth.getFullYear()) * 12 + (now.getMonth() - birth.getMonth());
  if (months < 12) return `${months} aylık`;
  const years = Math.floor(months / 12);
  return `${years} yaşında`;
}

// ─── Main handler ─────────────────────────────────────────────────────────────
serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  const url = new URL(req.url);
  const pathParts = url.pathname.split("/").filter(Boolean);

  // GET /shared/{token}
  if (req.method === "GET") {
    const sharedIdx = pathParts.indexOf("shared");
    if (sharedIdx !== -1 && pathParts[sharedIdx + 1]) {
      return handleWebView(pathParts[sharedIdx + 1], req);
    }
    return new Response("Not found", { status: 404 });
  }

  // POST / — Create link
  if (req.method === "POST") {
    return handleCreate(req);
  }

  return new Response("Method not allowed", { status: 405 });
});
