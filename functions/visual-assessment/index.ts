/**
 * LEGAL WARNING: This Edge Function performs AI-based visual observation of pet photos.
 * Before production launch:
 * - Verify no "medical device" classification under TR Tıbbi Cihaz Yönetmeliği
 * - KVKK compliance for health-related photo data
 * - Legal counsel review of all disclaimers
 * - DO NOT launch without legal sign-off.
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import Anthropic from "https://esm.sh/@anthropic-ai/sdk@0.27.3";

const DAILY_LIMITS: Record<string, number> = { premium: 3, pro_plus: 10 };

// Cost per assessment ~$0.03-0.08 with opus
const MAX_OUTPUT_TOKENS = 1000;

// ─── Category prompts ─────────────────────────────────────────────────────────

const CATEGORY_SYSTEM_PROMPTS: Record<string, string> = {
  skin_observation: `Sen Pawly'nin görsel gözlem asistanısın. Bu fotoğrafta bir evcil hayvanın CİLT bölgesi var.
Görevi: objektif gözlem yap, genel referans bilgi ver, aksiyon öner.
Lütfen şunları değerlendir: renk değişikliği, şişlik, lezyon, kuru/pul pul deri, kıl dökülmesi, yaralanma işareti.`,

  ear_check: `Sen Pawly'nin görsel gözlem asistanısın. Bu fotoğrafta bir evcil hayvanın KULAK bölgesi var.
Görevi: objektif gözlem yap. Değerlendir: kızarıklık, akıntı, şişlik, kir birikimi, kötü koku belirtisi, yabancı cisim.`,

  dental_observation: `Sen Pawly'nin görsel gözlem asistanısın. Bu fotoğrafta bir evcil hayvanın DİŞ/DİŞ ETİ bölgesi var.
Görevi: objektif gözlem yap. Değerlendir: diş taşı, renk değişikliği, kırık/çatlak, diş eti şişliği/kanaması, ağız kokusu işareti.`,

  body_condition: `Sen Pawly'nin görsel gözlem asistanısın. Bu fotoğrafta bir evcil hayvanın VÜCUT KONDÜSYONU görülüyor (yan profil).
Görevi: vücut kondisyon skoru değerlendirmesi yap (1-9 BCS skalası). Kaburga görünürlüğü, bel hattı, karın bölgesi, genel duruş.`,

  nail_check: `Sen Pawly'nin görsel gözlem asistanısın. Bu fotoğrafta bir evcil hayvanın TIRNAK/PATİ bölgesi var.
Görevi: objektif gözlem yap. Değerlendir: tırnak uzunluğu, tırnak rengi/sağlığı, pati arası, pati yastıkçığı durumu.`,

  wound_recovery: `Sen Pawly'nin görsel gözlem asistanısın. Bu fotoğrafta bir evcil hayvanın YARA veya OPERASYON BÖLGESİ var.
Görevi: iyileşme sürecini değerlendir. Değerlendir: kızarıklık derecesi, şişlik, akıntı, dikiş/yara yeri bütünlüğü, kabuk bağlama.
NOT: Cerrahi bölge gözleminde daha dikkatli ol, şüpheli bulgularda mutlaka vet yönlendirmesi yap.`,

  other_observation: `Sen Pawly'nin görsel gözlem asistanısın. Bu fotoğrafta bir evcil hayvan var.
Görevi: genel sağlık durumu gözlemi yap. Fotoğrafta ne gördüğünü objektif olarak tanımla ve genel değerlendirme yap.`,
};

const BASE_INSTRUCTIONS = `
GENEL KURALLAR:
1. Türkçe yanıt ver, sade ve anlaşılır dil kullan.
2. YANIT FORMATI — tam olarak bu yapıyı kullan:

📋 GÖRÜYORUm
[Fotoğrafta objektif olarak gördüklerin — 2-4 cümle]

💭 BU GÖRÜNTÜ
[Genel referans bilgisi — bu tür bulgular genellikle ne anlama gelir, 2-4 cümle]

🎯 ÖNERİYORUM
[Somut aksiyon adımları — madde madde]

3. İnsan yüzü veya insan vücudu fotoğrafı ise: "HUMAN_DETECTED: Bu fotoğrafta evcil hayvan göremiyorum. Lütfen sadece evcil hayvanınızın fotoğrafını yükleyin." yaz ve başka hiçbir şey ekleme.

4. Fotoğraf çok karanlık/bulanık/değerlendirilemiyor ise: "POOR_QUALITY: Fotoğraf değerlendirme için yeterli kalitede değil. Daha iyi ışıkta, yakın çekimde tekrar çekin." yaz.

5. Kategori yanlış görünüyorsa (örn: cilt için diş fotoğrafı): uyarı ver ama değerlendirmeye devam et.

6. KESİNLİKLE spesifik ilaç dozu veya teşhis koyma.

7. Yanıtının EN SONUNA, kullanıcıya görünmeyen gizli JSON ekle (tek satır, ## işaretleri arasında):
##{"concern_level":"normal|monitor|vet_recommended|urgent"}##

concern_level kriterleri:
- normal: Rutin gözlem, belirgin sorun yok
- monitor: 24-48 saat gözlem öner, endişe verici ama acil değil
- vet_recommended: Veteriner kontrolü önerilir, yakın zamanda
- urgent: Acil — bugün veteriner gerekli

8. Yanıt sonuna şu disclaimer'ı ekle:
"⚠️ Bu gözlem bilgilendirme amaçlıdır, tıbbi teşhis değildir. Sağlık endişeleriniz için veterinerinize danışın."`;

// ─── Concern level extraction ─────────────────────────────────────────────────

function extractConcernLevel(text: string): { level: string | null; cleanedText: string } {
  const jsonMatch = text.match(/##(\{[^}]+\})##/);
  let level: string | null = null;
  let cleanedText = text.replace(/##\{[^}]+\}##/g, "").trim();

  if (jsonMatch) {
    try {
      const parsed = JSON.parse(jsonMatch[1]);
      level = parsed.concern_level ?? null;
    } catch {
      // fall through to keyword detection
    }
  }

  // Keyword fallback
  if (!level) {
    const lower = cleanedText.toLowerCase();
    if (/acil|hemen vet|bugün vet|derhal/.test(lower)) level = "urgent";
    else if (/vet kontrolü|muayene öneri|veteriner'e gidin/.test(lower)) level = "vet_recommended";
    else if (/gözlem|takip|24|48 saat/.test(lower)) level = "monitor";
    else level = "normal";
  }

  return { level, cleanedText };
}

// ─── Main ────────────────────────────────────────────────────────────────────

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
  if (!anthropicKey) return jsonErr("Vision asistanı şu an kullanılamıyor.", 503);

  const supabase = createClient(supabaseUrl, serviceKey);

  // Auth
  const authHeader = req.headers.get("authorization");
  if (!authHeader) return jsonErr("Unauthorized", 401);
  const { data: { user }, error: authErr } = await supabase.auth.getUser(
    authHeader.replace("Bearer ", ""),
  );
  if (authErr || !user) return jsonErr("Unauthorized", 401);

  // Premium check — free tier completely blocked
  const { data: profile } = await supabase
    .from("profiles")
    .select("is_premium")
    .eq("id", user.id)
    .maybeSingle();

  if (!profile?.is_premium) {
    return json({ error: "PREMIUM_REQUIRED" }, 403);
  }

  const tier = "premium"; // TODO: distinguish pro_plus via RevenueCat entitlement
  const dailyLimit = DAILY_LIMITS[tier] ?? 3;

  // Quota check
  const today = new Date().toISOString().slice(0, 10);
  const { data: quota } = await supabase
    .from("visual_assessment_quota")
    .select("count")
    .eq("user_id", user.id)
    .eq("date", today)
    .maybeSingle();

  if ((quota?.count ?? 0) >= dailyLimit) {
    return json({ error: "RATE_LIMIT", limit: dailyLimit, tier });
  }

  // Consent check
  const { data: consent } = await supabase
    .from("vet_chat_consent")
    .select("user_id")
    .eq("user_id", user.id)
    .like("version", "visual%")
    .maybeSingle();
  if (!consent) return json({ error: "CONSENT_REQUIRED" }, 403);

  // Parse body
  const { pet_id, category, photo_storage_path, additional_context } = await req.json();

  if (!pet_id || !category || !photo_storage_path) {
    return jsonErr("pet_id, category ve photo_storage_path zorunlu.", 400);
  }

  const validCategories = [
    "skin_observation","ear_check","dental_observation",
    "body_condition","nail_check","wound_recovery","other_observation",
  ];
  if (!validCategories.includes(category)) return jsonErr("Geçersiz kategori.", 400);

  // Fetch photo from storage → base64
  const { data: signedUrlData } = await supabase.storage
    .from("visual-assessments")
    .createSignedUrl(photo_storage_path, 300);

  if (!signedUrlData?.signedUrl) return jsonErr("Fotoğraf yüklenemedi.", 500);

  const photoRes = await fetch(signedUrlData.signedUrl);
  if (!photoRes.ok) return jsonErr("Fotoğraf okunamadı.", 500);
  const photoBuffer = await photoRes.arrayBuffer();
  const base64Photo = btoa(String.fromCharCode(...new Uint8Array(photoBuffer)));

  // Pet context
  const { data: pet } = await supabase
    .from("pets")
    .select("name, species, breed, birth_date, weight_kg")
    .eq("id", pet_id)
    .maybeSingle();

  const petContext = pet
    ? `Pet: ${pet.name}, ${pet.species === "dog" ? "Köpek" : "Kedi"}${pet.breed ? `, ${pet.breed}` : ""}${pet.weight_kg ? `, ${pet.weight_kg} kg` : ""}.`
    : "Pet bilgisi mevcut değil.";

  const userContent: Anthropic.MessageParam["content"] = [
    {
      type: "image",
      source: { type: "base64", media_type: "image/jpeg", data: base64Photo },
    },
    {
      type: "text",
      text: [
        petContext,
        additional_context ? `Kullanıcı notu: ${additional_context}` : "",
        `Kategori: ${category}`,
      ].filter(Boolean).join("\n"),
    },
  ];

  // Anthropic call
  const anthropic = new Anthropic({ apiKey: anthropicKey });
  let rawResponse = "";
  let inputTokens = 0;
  let outputTokens = 0;

  try {
    const categoryPrompt = CATEGORY_SYSTEM_PROMPTS[category] ?? CATEGORY_SYSTEM_PROMPTS.other_observation;
    const response = await anthropic.messages.create({
      model: "claude-opus-4-7",
      max_tokens: MAX_OUTPUT_TOKENS,
      system: categoryPrompt + BASE_INSTRUCTIONS,
      messages: [{ role: "user", content: userContent }],
    });

    rawResponse = response.content
      .filter((b) => b.type === "text")
      .map((b) => (b as { type: "text"; text: string }).text)
      .join("");

    inputTokens = response.usage.input_tokens;
    outputTokens = response.usage.output_tokens;
  } catch (err) {
    console.error("Anthropic vision error:", err);
    return jsonErr("Görsel asistan şu an ulaşılamıyor.", 503);
  }

  // Post-processing
  const { level: concernLevel, cleanedText: aiResponse } = extractConcernLevel(rawResponse);

  // Human detection
  const isHumanDetected = aiResponse.startsWith("HUMAN_DETECTED:");
  const isPoorQuality = aiResponse.startsWith("POOR_QUALITY:");

  // Save to DB
  const { data: saved, error: saveErr } = await supabase
    .from("visual_assessments")
    .insert({
      user_id: user.id,
      pet_id,
      assessment_category: category,
      photo_url: photo_storage_path,
      additional_context: additional_context ?? null,
      ai_response: aiResponse,
      ai_concern_level: isHumanDetected || isPoorQuality ? null : (concernLevel as string | null),
      tokens_used: inputTokens + outputTokens,
      flagged_for_review: concernLevel === "urgent",
    })
    .select("id")
    .single();

  if (saveErr) return jsonErr("Değerlendirme kaydedilemedi.", 500);

  // Update quota
  await supabase.from("visual_assessment_quota").upsert(
    { user_id: user.id, date: today, count: (quota?.count ?? 0) + 1, tier },
    { onConflict: "user_id,date" },
  );

  return json({
    assessment_id: saved.id,
    ai_response: aiResponse,
    concern_level: isHumanDetected || isPoorQuality ? null : concernLevel,
    is_human_detected: isHumanDetected,
    is_poor_quality: isPoorQuality,
    tokens_used: inputTokens + outputTokens,
    quota: { used: (quota?.count ?? 0) + 1, limit: dailyLimit, tier },
  });
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" },
  });
}

function jsonErr(message: string, status = 400) {
  return json({ error: message }, status);
}
