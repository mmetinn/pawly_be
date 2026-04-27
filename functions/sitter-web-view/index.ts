import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const SECTION_LABELS: Record<string, string> = {
  feeding: "🍽️ Beslenme",
  medications: "💊 İlaçlar",
  walking: "🐾 Yürüyüş",
  behavior: "🧠 Karakter & Alışkanlıklar",
  house_rules: "🏠 Ev Kuralları",
  emergency: "🚨 Acil Durum",
  favorites: "⭐ Favoriler",
  avoid: "🚫 Yapılmaması Gerekenler",
  other: "📋 Diğer",
};

serve(async (req) => {
  const url = new URL(req.url);
  const token = url.pathname.split("/").pop();
  const isPost = req.method === "POST";

  if (!token || token === "sitter-web-view") {
    return htmlError("Geçersiz bağlantı.");
  }

  const svc = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY);

  const { data: assignment } = await svc
    .from("sitter_assignments")
    .select("*")
    .eq("web_access_token", token)
    .in("status", ["scheduled", "active"])
    .maybeSingle();

  if (!assignment) return htmlError("Bu bağlantı geçersiz veya süresi dolmuş.");

  // Activate if scheduled and start time passed
  if (assignment.status === "scheduled" && new Date(assignment.starts_at) <= new Date()) {
    await svc.from("sitter_assignments").update({ status: "active" }).eq("id", assignment.id);
  }

  if (new Date(assignment.ends_at) < new Date()) {
    await svc.from("sitter_assignments").update({ status: "completed" }).eq("id", assignment.id);
    return htmlError("Bakım görevi sona ermiştir. Teşekkürler!");
  }

  // Handle update submission from sitter
  if (isPost) {
    const formData = await req.formData();
    const content = formData.get("content")?.toString().trim();
    const noteType = formData.get("note_type")?.toString() ?? "daily_update";
    if (content) {
      await svc.from("sitter_handoff_notes").insert({
        sitter_assignment_id: assignment.id,
        note_type: noteType,
        content,
        written_by: assignment.sitter_user_id ?? null,
        written_by_role: "sitter",
      });
    }
    // Mark onboarding done if first time
    if (!assignment.onboarding_completed_at) {
      await svc.from("sitter_assignments").update({ onboarding_completed_at: new Date().toISOString() }).eq("id", assignment.id);
    }
    // Redirect back to the same page
    return new Response(null, { status: 303, headers: { Location: req.url } });
  }

  const [petRes, careRes, notesRes] = await Promise.all([
    svc.from("pets").select("*").eq("id", assignment.pet_id).single(),
    svc.from("care_instructions").select("*").eq("pet_id", assignment.pet_id).order("section").order("sort_order"),
    svc.from("sitter_handoff_notes").select("*").eq("sitter_assignment_id", assignment.id).order("created_at", { ascending: false }).limit(20),
  ]);

  const pet = petRes.data;
  const careInstructions = careRes.data ?? [];
  const notes = notesRes.data ?? [];

  const essential = careInstructions.filter(c => c.is_essential);
  const showOnboarding = !assignment.onboarding_completed_at;

  const speciesEmoji = pet?.species === "dog" ? "🐕" : pet?.species === "cat" ? "🐈" : "🐾";
  const endsAt = new Date(assignment.ends_at);
  const daysLeft = Math.ceil((endsAt.getTime() - Date.now()) / 86_400_000);
  const fmt = (d: string) => new Date(d).toLocaleString("tr-TR", { day: "numeric", month: "long", hour: "2-digit", minute: "2-digit" });

  const bySection = careInstructions.reduce<Record<string, typeof careInstructions>>((acc, c) => {
    (acc[c.section] ??= []).push(c);
    return acc;
  }, {});

  const sectionHtml = Object.entries(bySection).map(([sec, items]) =>
    `<div class="section">
      <h3 class="sec-title">${SECTION_LABELS[sec] ?? sec}</h3>
      ${items.map(item => `
        <div class="instruction ${item.is_essential ? "essential" : ""}">
          ${item.is_essential ? '<span class="badge">Önemli</span>' : ""}
          <p>${escHtml(item.content)}</p>
        </div>`).join("")}
    </div>`
  ).join("");

  const notesHtml = notes.length === 0
    ? `<p class="empty">Henüz mesaj yok.</p>`
    : notes.map(n => `
      <div class="note ${n.written_by_role === "sitter" ? "note-sitter" : "note-owner"}">
        <div class="note-meta">${n.written_by_role === "sitter" ? "👤 Sen" : "👑 Sahip"} · ${fmt(n.created_at)}</div>
        <p>${escHtml(n.content)}</p>
      </div>`).join("");

  const html = `<!DOCTYPE html>
<html lang="tr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${String(pet?.name ?? "Pet")} — Bakım Rehberi</title>
<style>
*{box-sizing:border-box}
body{font-family:system-ui,-apple-system,sans-serif;margin:0;background:#f9fafb;color:#1f2937;}
.hero{background:linear-gradient(135deg,#059669,#10b981);color:#fff;padding:24px 16px;text-align:center;}
.hero .emoji{font-size:64px;display:block;margin-bottom:8px;}
.hero h1{margin:0;font-size:1.75rem;font-weight:800;}
.hero .meta{opacity:.85;font-size:.9rem;margin-top:6px;}
.countdown{background:#065f46;padding:10px 16px;text-align:center;font-size:.9rem;font-weight:700;}
.container{max-width:600px;margin:0 auto;padding:16px;}
.card{background:#fff;border-radius:12px;padding:20px;margin-bottom:12px;box-shadow:0 1px 4px rgba(0,0,0,.06);}
.section{margin-bottom:20px;}
.sec-title{font-size:1rem;font-weight:700;margin:0 0 10px;}
.instruction{background:#f9fafb;border-radius:8px;padding:12px;margin-bottom:8px;position:relative;}
.instruction.essential{background:#ecfdf5;border-left:4px solid #059669;}
.badge{background:#059669;color:#fff;font-size:.7rem;font-weight:700;padding:2px 6px;border-radius:10px;display:inline-block;margin-bottom:4px;}
.btn{display:block;width:100%;padding:14px;border:none;border-radius:12px;font-size:1rem;font-weight:700;cursor:pointer;text-align:center;text-decoration:none;margin-bottom:8px;}
.btn-green{background:#059669;color:#fff;}
.btn-red{background:#dc2626;color:#fff;}
.btn-gray{background:#e5e7eb;color:#374151;}
textarea{width:100%;border:2px solid #e5e7eb;border-radius:8px;padding:10px;font-size:.9rem;resize:vertical;min-height:80px;font-family:inherit;}
textarea:focus{outline:none;border-color:#059669;}
select{width:100%;border:2px solid #e5e7eb;border-radius:8px;padding:10px;font-size:.9rem;background:#fff;margin-bottom:8px;}
.note{border-radius:8px;padding:12px;margin-bottom:8px;}
.note-sitter{background:#eff6ff;border-left:3px solid #3b82f6;}
.note-owner{background:#f0fdf4;border-left:3px solid #059669;}
.note-meta{font-size:.75rem;color:#6b7280;margin-bottom:4px;}
.emergency-card{background:#fef2f2;border:2px solid #dc2626;border-radius:12px;padding:20px;text-align:center;margin-bottom:12px;}
.emergency-card h3{color:#dc2626;margin:0 0 8px;}
.contact-item{display:flex;align-items:center;gap:10px;padding:10px 0;border-bottom:1px solid #e5e7eb;}
.contact-item:last-child{border-bottom:none;}
.tabs{display:flex;gap:4px;margin-bottom:16px;}
.tab{flex:1;padding:10px;border:none;background:#e5e7eb;border-radius:8px;font-size:.85rem;font-weight:600;cursor:pointer;}
.tab.active{background:#059669;color:#fff;}
.section-tab{display:none;}.section-tab.active{display:block;}
.onboarding{position:fixed;top:0;left:0;right:0;bottom:0;background:#059669;color:#fff;display:flex;flex-direction:column;align-items:center;justify-content:center;padding:24px;z-index:100;}
.onboarding h2{font-size:1.5rem;font-weight:800;margin:0 0 12px;text-align:center;}
.onboarding p{text-align:center;opacity:.9;line-height:1.6;margin:0 0 24px;}
.onboarding .step{font-size:.85rem;opacity:.7;margin-bottom:16px;}
.download-cta{background:#fff;color:#059669;border:none;border-radius:12px;padding:12px 24px;font-size:.9rem;font-weight:700;cursor:pointer;margin-top:8px;}
.empty{color:#9ca3af;font-style:italic;font-size:.875rem;}
.footer{text-align:center;padding:24px 16px;color:#9ca3af;font-size:.8rem;}
.footer .powered{font-weight:700;color:#059669;}
</style>
</head>
<body>

${showOnboarding && essential.length > 0 ? `
<div class="onboarding" id="onboarding">
  <div class="step">📋 Bakım Rehberi</div>
  <div style="font-size:80px;margin-bottom:16px;">${speciesEmoji}</div>
  <h2>Hoş geldin! ${escHtml(String(pet?.name ?? "Pet"))}'a bakacaksın 🐾</h2>
  <p>Başlamadan önce <strong>${assignment.sitter_name}</strong>, sahip senin için önemli talimatları bıraktı. Lütfen oku.</p>
  <div style="background:rgba(255,255,255,.15);border-radius:12px;padding:16px;width:100%;margin-bottom:20px;max-height:40vh;overflow-y:auto;">
    ${essential.map(e => `<div style="margin-bottom:12px;padding-bottom:12px;border-bottom:1px solid rgba(255,255,255,.2);"><strong>• ${escHtml(e.content)}</strong></div>`).join("")}
  </div>
  <form method="POST" style="width:100%;">
    <input type="hidden" name="content" value="Bakım rehberini okudum ve anladım. Göreve başlıyorum!">
    <input type="hidden" name="note_type" value="daily_update">
    <button type="submit" class="btn btn-green">✅ Anladım, Göreve Başla!</button>
  </form>
  <p style="font-size:.8rem;opacity:.7;margin-top:12px;">Talimatlar daha sonra da görüntülenebilir.</p>
</div>
` : ""}

<div class="hero">
  <span class="emoji">${speciesEmoji}</span>
  <h1>${escHtml(String(pet?.name ?? "Pet"))}</h1>
  <div class="meta">${pet?.breed ?? ""} ${pet?.gender === "male" ? "· Erkek" : pet?.gender === "female" ? "· Dişi" : ""}</div>
</div>

<div class="countdown">
  ${daysLeft > 0
    ? `⏰ Göreve ${daysLeft} gün kaldı · ${fmt(assignment.ends_at)} tarihinde tamamlanıyor`
    : `🏁 Görev bugün bitiyor!`
  }
</div>

<div class="container">

  <div class="tabs">
    <button class="tab active" onclick="showTab('care')">🏠 Bakım</button>
    <button class="tab" onclick="showTab('messages')">💬 Mesajlar</button>
    <button class="tab" onclick="showTab('emergency')">🚨 Acil</button>
  </div>

  <!-- CARE TAB -->
  <div id="tab-care" class="section-tab active">
    ${sectionHtml || `<p class="empty">Sahip henüz bakım talimatı eklememiş.</p>`}
  </div>

  <!-- MESSAGES TAB -->
  <div id="tab-messages" class="section-tab">
    <div class="card">
      <h3 style="margin:0 0 12px;font-size:1rem;font-weight:700;">💬 Owner'a Mesaj Gönder</h3>
      <form method="POST">
        <select name="note_type">
          <option value="daily_update">📋 Günlük Güncelleme</option>
          <option value="question">❓ Soru</option>
          <option value="concern">⚠️ Endişe</option>
        </select>
        <textarea name="content" placeholder="Mesajınızı yazın... (örn: Öğle yemeğini yedi, çok neşeliydi 🐾)" required></textarea>
        <button type="submit" class="btn btn-green">📤 Gönder</button>
      </form>
    </div>

    <div class="card">
      <h3 style="margin:0 0 12px;font-size:1rem;font-weight:700;">📨 Mesajlar</h3>
      ${notesHtml}
    </div>
  </div>

  <!-- EMERGENCY TAB -->
  <div id="tab-emergency" class="section-tab">
    <div class="emergency-card">
      <h3>🚨 Acil Durum</h3>
      <p style="color:#6b7280;font-size:.9rem;margin:0 0 12px;">Ciddi bir sorun varsa hemen Owner'a haber ver.</p>
      <form method="POST">
        <input type="hidden" name="note_type" value="emergency">
        <textarea name="content" placeholder="Acil durumu açıklayın..." required style="border-color:#dc2626;"></textarea>
        <button type="submit" class="btn btn-red">🚨 ACİL HABER VER</button>
      </form>
    </div>

    ${assignment.sitter_phone || assignment.emergency_contact_owner ? `
    <div class="card">
      <h3 style="margin:0 0 12px;font-size:1rem;font-weight:700;">📞 Acil İletişim</h3>
      <div class="contact-item">
        <span style="font-size:24px;">👑</span>
        <div>
          <strong>Sahip</strong><br>
          <span style="color:#6b7280;font-size:.9rem;">Pawly uygulamasından bildirim alıyor</span>
        </div>
      </div>
    </div>
    ` : ""}
  </div>

  <div style="background:#fff;border-radius:12px;padding:20px;text-align:center;margin-bottom:12px;">
    <p style="font-size:.9rem;color:#374151;margin:0 0 12px;">Daha iyi deneyim için Pawly'i indir 🐾</p>
    <p style="font-size:.8rem;color:#6b7280;margin:0 0 16px;">Owner ile anlık iletişim, bildirimler ve daha fazlası</p>
    <a href="https://pawly.app/download" class="btn btn-green" style="display:inline-block;width:auto;padding:12px 24px;">📱 Pawly'i İndir</a>
  </div>

  <div class="footer">
    <p>Bu bakım rehberi <span class="powered">Pawly</span> uygulaması aracılığıyla paylaşılmıştır.</p>
    <p style="font-size:.75rem;color:#d1d5db;">Görev: ${fmt(assignment.starts_at)} — ${fmt(assignment.ends_at)}</p>
  </div>
</div>

<script>
function showTab(name) {
  document.querySelectorAll('.section-tab').forEach(t => t.classList.remove('active'));
  document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
  document.getElementById('tab-' + name).classList.add('active');
  event.target.classList.add('active');
}
</script>
</body>
</html>`;

  return new Response(html, { status: 200, headers: { "Content-Type": "text/html; charset=utf-8" } });
});

function htmlError(msg: string): Response {
  return new Response(`<!DOCTYPE html><html lang="tr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Pawly</title><style>body{font-family:system-ui,sans-serif;display:flex;align-items:center;justify-content:center;min-height:100vh;margin:0;background:#f0fdf4;}.card{background:#fff;border-radius:16px;padding:40px 28px;text-align:center;max-width:380px;width:90%;}.logo{font-size:3rem;}</style></head><body><div class="card"><div class="logo">🐾</div><h2 style="color:#1f2937;">${msg}</h2><p style="color:#6b7280;font-size:.9rem;">Bakım görevi sahibiyle iletişime geçin.</p></div></body></html>`, {
    status: 410,
    headers: { "Content-Type": "text/html; charset=utf-8" },
  });
}

function escHtml(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}
