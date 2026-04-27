/**
 * LEGAL WARNING: This Edge Function powers an AI veterinary assistant.
 * Before production launch:
 * - Verify TR medical device regulation compliance (Tıbbi Cihaz Yönetmeliği)
 * - Ensure KVKK (6698 sayılı Kanun) compliance for health data
 * - Have legal counsel review disclaimers and Terms of Service
 * - Confirm user consent is legally valid
 * DO NOT launch without legal sign-off.
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import Anthropic from "https://esm.sh/@anthropic-ai/sdk@0.27.3";

const DAILY_LIMITS: Record<string, number> = {
  free: 3,
  premium: 30,
  pro_plus: 100,
};

const MAX_OUTPUT_TOKENS = 800;
const MAX_INPUT_TOKENS = 4000;
const MAX_HISTORY_MESSAGES = 10;
const MIN_RESPONSE_CHARS = 50;

// ─── Pre-processing ───────────────────────────────────────────────────────────

const EMERGENCY_KEYWORDS_TR = [
  "kan ", "kanıyor", "kan geliyor", "kanaması",
  "nefes alamıyor", "nefes almıyor", "soluk alamıyor", "nefes durdu",
  "bayıldı", "baygın", "bilinç yok", "tepki vermiyor",
  "konvülziyon", "nöbet geçiriyor", "kasılıyor", "sara nöbeti",
  "çikolata yedi", "üzüm yedi", "kuru üzüm yedi", "soğan yedi", "sarımsak yedi",
  "ilaç yuttu", "ilaç yedi", "zehirlendi", "zehirlenme",
  "doğum yapamıyor", "doğurmuyor", "şişmiş karın", "karın şişliği",
  "gözü döndü", "yere yıkıldı", "kalp durdu",
];

const PROFANITY_TR = ["orospu", "siktir", "amk", "göt", "piç", "oç"];
const PROFANITY_EN = ["fuck", "shit", "bitch", "asshole", "cunt"];

const OFF_TOPIC_KEYWORDS = [
  "kod yaz", "program yaz", "javascript", "python", "matematik", "hesapla",
  "şarkı", "müzik", "film öner", "haber", "tarih bilgisi", "siyaset",
  "döviz", "borsa", "kripto", "bitcoin",
];

// Dangerous dose pattern: number + dose unit
const DOSE_PATTERN = /\b\d+(\.\d+)?\s*(mg|ml|cc|tablet|hap|kapsül|iu|mcg)\b/gi;

const DISCLAIMER_TR =
  "\n\n---\n⚠️ *Bu bilgiler genel bilgilendirme amaçlıdır, tıbbi tavsiye değildir. Evcil hayvanınızın sağlık durumu için lütfen bir veterinere başvurun.*";

function detectEmergency(text: string): boolean {
  const lower = text.toLowerCase();
  return EMERGENCY_KEYWORDS_TR.some((kw) => lower.includes(kw));
}

function detectProfanity(text: string): boolean {
  const lower = text.toLowerCase();
  return [...PROFANITY_TR, ...PROFANITY_EN].some((w) => lower.includes(w));
}

function detectOffTopic(text: string): boolean {
  const lower = text.toLowerCase();
  return OFF_TOPIC_KEYWORDS.some((kw) => lower.includes(kw));
}

function detectDangerous(text: string): boolean {
  // "X mg verebilir miyim" type patterns
  return DOSE_PATTERN.test(text) && /verebilir|verilir|versem|versek/i.test(text);
}

function detectDoseInOutput(text: string): boolean {
  // Block output containing specific doses
  return DOSE_PATTERN.test(text);
}

// ─── System Prompt ────────────────────────────────────────────────────────────

function buildSystemPrompt(petContext: string, isPro: boolean): string {
  return `Sen Pawly'nin yapay zeka destekli vet asistanısın. Görevin evcil hayvan sahiplerine Türkçe, sade ve anlaşılır bilgi vermek.

KURALLAR:
1. SADECE evcil hayvan sağlığı ve bakımı hakkında konuş. Başka konularda "Bu konuda yardımcı olamıyorum" de.
2. KESİNLİKLE ilaç dozu (mg, ml, tablet sayısı) önerme. Doz sorusunda: "İlaç dozu yalnızca veteriner tarafından belirlenir."
3. Acil semptom gördüğünde (kanama, nöbet, bilinç kaybı, zehirlenme şüphesi) cevabının başında "🚨 ACİL DURUM" yaz.
4. Her cevabın sonunda disclaimer ekle.
5. Türkçe yanıt ver. Tıbbi terimler için parantez içinde Türkçe açıklama ekle.
6. Cevabın bilgilendirici ama kısa olsun (maksimum ${isPro ? "400" : "250"} kelime).
7. Kullanıcının adını, konumunu asla tekrar etme veya kaydet.

PET BAĞLAMI:
${petContext}

DİSCLAİMER: Her cevabın sonunda şu metni ekle: "⚠️ Bu bilgiler genel bilgilendirme amaçlıdır, tıbbi tavsiye değildir."`;
}

// ─── Main Handler ─────────────────────────────────────────────────────────────

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, {
      headers: {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Headers": "authorization, content-type",
        "Access-Control-Allow-Methods": "POST",
      },
    });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const anthropicKey = Deno.env.get("ANTHROPIC_API_KEY");

  if (!anthropicKey) return jsonErr("AI asistanı şu an kullanılamıyor.", 503);

  // Auth
  const authHeader = req.headers.get("authorization");
  if (!authHeader) return jsonErr("Unauthorized", 401);
  const supabase = createClient(supabaseUrl, serviceKey);
  const { data: { user }, error: authErr } = await supabase.auth.getUser(
    authHeader.replace("Bearer ", ""),
  );
  if (authErr || !user) return jsonErr("Unauthorized", 401);

  // Parse body
  const body = await req.json();
  const {
    conversation_id,
    message,
    pet_id,
  }: { conversation_id?: string; message: string; pet_id?: string } = body;

  if (!message?.trim()) return jsonErr("Mesaj boş olamaz.", 400);

  // ── Pre-processing ──
  if (message.length > 1000) return jsonErr("Mesaj çok uzun (max 1000 karakter).", 400);
  if (detectProfanity(message)) return jsonErr("Uygunsuz içerik tespit edildi.", 400);
  if (detectOffTopic(message)) {
    return json({ reply: "Bu konu Pawly Vet Asistanı'nın kapsamı dışında. Evcil hayvanınızla ilgili sorularınızı yanıtlamaktan memnuniyet duyarım.", emergency: false });
  }
  if (detectDangerous(message)) {
    return json({ reply: "İlaç dozu yalnızca veteriner tarafından belirlenir. Lütfen bir veterinere danışın.\n\n⚠️ Bu bilgiler genel bilgilendirme amaçlıdır, tıbbi tavsiye değildir.", emergency: false });
  }

  // Emergency pre-check (before LLM call)
  const isEmergency = detectEmergency(message);
  if (isEmergency) {
    // Still call LLM but flag it; pre-canned emergency header added below
  }

  // ── Consent check ──
  const { data: consent } = await supabase
    .from("vet_chat_consent")
    .select("user_id")
    .eq("user_id", user.id)
    .maybeSingle();
  if (!consent) return jsonErr("CONSENT_REQUIRED", 403);

  // ── Rate limit ──
  const today = new Date().toISOString().slice(0, 10);
  const { data: profile } = await supabase
    .from("profiles")
    .select("is_premium")
    .eq("id", user.id)
    .maybeSingle();
  const tier = profile?.is_premium ? "premium" : "free";
  const dailyLimit = DAILY_LIMITS[tier] ?? DAILY_LIMITS.free;

  const { data: usage } = await supabase
    .from("vet_chat_usage")
    .select("message_count")
    .eq("user_id", user.id)
    .eq("date", today)
    .maybeSingle();

  if ((usage?.message_count ?? 0) >= dailyLimit) {
    return json({ reply: null, error: "RATE_LIMIT", tier, limit: dailyLimit });
  }

  // ── Get or create conversation ──
  let convId = conversation_id;
  if (!convId) {
    const { data: newConv, error: convErr } = await supabase
      .from("vet_chat_conversations")
      .insert({ user_id: user.id, pet_id: pet_id ?? null, last_message_at: new Date().toISOString() })
      .select("id")
      .single();
    if (convErr) return jsonErr("Konuşma başlatılamadı.", 500);
    convId = newConv.id;
  }

  // ── Build pet context ──
  let petContext = "Pet bilgisi sağlanmadı.";
  if (pet_id) {
    const { data: pet } = await supabase
      .from("pets")
      .select("name, species, breed, birth_date, weight_kg, is_neutered")
      .eq("id", pet_id)
      .maybeSingle();
    if (pet) {
      const age = pet.birth_date
        ? `${Math.floor((Date.now() - new Date(pet.birth_date).getTime()) / (365.25 * 24 * 3600 * 1000))} yaşında`
        : "yaş bilinmiyor";
      petContext = `Pet: ${pet.name}, ${pet.species === "dog" ? "Köpek" : "Kedi"}, ${pet.breed ?? "ırk bilinmiyor"}, ${age}, ${pet.weight_kg ? pet.weight_kg + " kg" : "kilo bilinmiyor"}, ${pet.is_neutered ? "kısırlaştırılmış" : "kısırlaştırılmamış"}.`;

      // Active medications
      const { data: meds } = await supabase
        .from("medications")
        .select("name, dosage")
        .eq("pet_id", pet_id)
        .eq("is_active", true)
        .limit(5);
      if (meds && meds.length > 0) {
        petContext += ` Aktif ilaçlar: ${meds.map((m) => `${m.name}${m.dosage ? " " + m.dosage : ""}`).join(", ")}.`;
      }
    }
  }

  // ── Fetch history ──
  const { data: historyRows } = await supabase
    .from("vet_chat_messages")
    .select("role, content")
    .eq("conversation_id", convId)
    .order("created_at", { ascending: false })
    .limit(MAX_HISTORY_MESSAGES);

  const history = (historyRows ?? []).reverse();

  // ── Save user message ──
  await supabase.from("vet_chat_messages").insert({
    conversation_id: convId,
    role: "user",
    content: message,
  });

  // ── Call Anthropic ──
  const anthropic = new Anthropic({ apiKey: anthropicKey });
  const messages: Anthropic.MessageParam[] = [
    ...history
      .filter((m) => m.role === "user" || m.role === "assistant")
      .map((m) => ({ role: m.role as "user" | "assistant", content: m.content })),
    { role: "user", content: message },
  ];

  // Truncate if too long (rough estimate: 4 chars ≈ 1 token)
  let totalChars = messages.reduce((s, m) => s + (typeof m.content === "string" ? m.content.length : 0), 0);
  while (totalChars > MAX_INPUT_TOKENS * 4 && messages.length > 2) {
    totalChars -= typeof messages[0].content === "string" ? messages[0].content.length : 0;
    messages.shift();
  }

  let assistantReply = "";
  let inputTokens = 0;
  let outputTokens = 0;

  try {
    const isPro = tier === "premium"; // treat premium as pro for now
    const response = await anthropic.messages.create({
      model: "claude-haiku-4-5-20251001",
      max_tokens: MAX_OUTPUT_TOKENS,
      system: buildSystemPrompt(petContext, isPro),
      messages,
    });

    assistantReply = response.content
      .filter((b) => b.type === "text")
      .map((b) => (b as { type: "text"; text: string }).text)
      .join("");

    inputTokens = response.usage.input_tokens;
    outputTokens = response.usage.output_tokens;
  } catch (err) {
    console.error("Anthropic error:", err);
    // Still show emergency info if applicable
    if (isEmergency) {
      return json({
        reply: "🚨 ACİL DURUM: Bu durumda lütfen hemen bir veterinere başvurun!\n\n⚠️ AI asistanı şu an ulaşılamıyor.",
        emergency: true,
        conversation_id: convId,
      });
    }
    return jsonErr("Asistan şu an ulaşılamıyor, lütfen biraz sonra tekrar deneyin.", 503);
  }

  // ── Post-processing ──
  let flagged = false;
  let flagReason = "";

  if (detectDoseInOutput(assistantReply)) {
    assistantReply = "Bu soruyu yanıtlamak için yeterli bilgiye sahip değilim. İlaç dozu konusunda lütfen bir veterinere başvurun." + DISCLAIMER_TR;
    flagged = true;
    flagReason = "dose_in_output";
  }

  if (assistantReply.trim().length < MIN_RESPONSE_CHARS) {
    assistantReply = "Bu konuda yardımcı olmak için daha fazla bilgiye ihtiyacım var. Evcil hayvanınızın belirtilerini detaylandırır mısınız?" + DISCLAIMER_TR;
  }

  if (!assistantReply.includes("bilgilendirme amaçlıdır") && !assistantReply.includes("tıbbi tavsiye")) {
    assistantReply += DISCLAIMER_TR;
  }

  const emergencyInOutput = isEmergency || assistantReply.startsWith("🚨 ACİL");

  // ── Save assistant message ──
  const { data: savedMsg } = await supabase
    .from("vet_chat_messages")
    .insert({
      conversation_id: convId,
      role: "assistant",
      content: assistantReply,
      metadata: { input_tokens: inputTokens, output_tokens: outputTokens, model: "claude-haiku-4-5-20251001", tier },
      flagged,
      flag_reason: flagReason || null,
    })
    .select("id")
    .single();

  // ── Update conversation ──
  await supabase.from("vet_chat_conversations").update({
    last_message_at: new Date().toISOString(),
    emergency_detected: emergencyInOutput || undefined,
    emergency_referred_at: emergencyInOutput ? new Date().toISOString() : undefined,
    updated_at: new Date().toISOString(),
  }).eq("id", convId);

  // ── Update usage ──
  const estimatedCost = (inputTokens * 0.00000025 + outputTokens * 0.00000125); // Haiku pricing
  await supabase.from("vet_chat_usage").upsert(
    {
      user_id: user.id,
      date: today,
      message_count: (usage?.message_count ?? 0) + 1,
      total_tokens: inputTokens + outputTokens,
      estimated_cost_usd: estimatedCost,
      tier_at_time: tier,
    },
    { onConflict: "user_id,date" },
  );

  return json({
    reply: assistantReply,
    emergency: emergencyInOutput,
    conversation_id: convId,
    message_id: savedMsg?.id,
    usage: {
      used: (usage?.message_count ?? 0) + 1,
      limit: dailyLimit,
      tier,
    },
  });
});

// ─── Helpers ─────────────────────────────────────────────────────────────────

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" },
  });
}

function jsonErr(message: string, status = 400) {
  return json({ error: message }, status);
}
