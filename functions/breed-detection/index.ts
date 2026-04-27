import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import Anthropic from "https://esm.sh/@anthropic-ai/sdk@0.27.3";

// Monthly limits: free=1 (viral hook), premium=10, pro_plus=unlimited
const MONTHLY_LIMITS: Record<string, number> = { free: 1, premium: 10, pro_plus: 9999 };

const SYSTEM_PROMPT = `Sen Pawly'nin cins tahmin asistanısın. Köpek veya kedi fotoğrafından görünür özelliklere bakarak ÇOĞUNLUKLA HANGİ CİNSE BENZEDİĞİNİ tahmin edersin. Bu bir genetik test değildir, eğlenceli görsel tahmindir.

YAKLAŞIM:
- Sadece görsel özelliklere bak: tüy uzunluğu/rengi/dokusu, kulak şekli, kuyruk, vücut yapısı, kafa şekli, göz rengi.
- Top 3 olası cins ver. Her biri için "%40 Golden Retriever benzeri" şeklinde yüzde ver.
- Karışık cins (mixed breed) çok yaygın — "saf cins değil" demekten çekinme.
- TR sokak hayvanı bağlamı: "Anadolu sokak köpeği", "Anadolu Aslanı", "TR sokak kedisi" gibi yerel kategoriler kullan.
- Belirsizse "Karışık cins, dominant özellikler X" formatında ver.

YAPMAMA:
- Asla kesin cins teşhisi koyma ("%100 Labrador" gibi)
- Sağlık tahmini yapma
- "Saldırgan olur" gibi yargılayıcı davranış tahmini yapma
- Pit Bull, American Staffordshire gibi TR'de tartışmalı cinsleri tek başına söyleme — "molossoid grup" gibi nötr kategori kullan
- İnsan fotoğrafı varsa: HUMAN_DETECTED yaz, başka hiçbir şey ekleme
- Pet net görünmüyorsa: POOR_QUALITY yaz

TÜRKÇE cins referansları:
- Köpek TR: Kangal (Anadolu Çoban), Akbaş, Kars Çoban, Çatalburun, Anadolu sokak köpeği
- Köpek yaygın: Golden Retriever, Labrador, German Shepherd, Pomeranian, Maltese, Yorkshire Terrier, Husky, Border Collie, Jack Russell, Beagle
- Kedi TR: Van Kedisi, Ankara Kedisi (Türk Angorası), TR sokak kedisi, Tekir, Üç renk
- Kedi yaygın: British Shorthair, Scottish Fold, Persian, Maine Coon, Ragdoll, Sphynx, Bengal

YANIT FORMATI — tam olarak bu JSON yapısını kullan, görünmez şekilde ## işaretleri arasında:
##{"predictions":[{"breed":"Cins Adı","percentage":40,"traits":["özellik 1","özellik 2","özellik 3"]},{"breed":"Cins 2","percentage":35,"traits":["özellik 1","özellik 2"]},{"breed":"Cins 3","percentage":25,"traits":["özellik 1"]}],"personality":"Karakter notu: enerji seviyesi, bakım ihtiyacı, genel mizaç (2-3 cümle)","display_text":"Bu güzel [hayvan] muhtemelen:\\n- %40 [Cins 1] benzeri\\n- %35 [Cins 2] benzeri\\n- %25 [Cins 3] benzeri\\n\\n[Karakter notu]\\n\\n⚠️ Bu eğlenceli bir tahmindir. Kesin cins için DNA testi gerekir."}##

Türkçe yanıt ver, samimi ve eğlenceli ton. Kullanıcıyı heyecanlandır!`;

interface BreedPrediction {
  breed: string;
  percentage: number;
  traits: string[];
}

interface ParsedResult {
  predictions: BreedPrediction[];
  personality: string;
  display_text: string;
}

function parseResult(text: string): ParsedResult | null {
  const match = text.match(/##(\{[\s\S]*?\})##/);
  if (!match) return null;
  try {
    return JSON.parse(match[1]) as ParsedResult;
  } catch {
    return null;
  }
}

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
  if (!anthropicKey) return jsonErr("Servis şu an kullanılamıyor.", 503);

  const supabase = createClient(supabaseUrl, serviceKey);

  // Auth
  const authHeader = req.headers.get("authorization");
  if (!authHeader) return jsonErr("Unauthorized", 401);
  const { data: { user }, error: authErr } = await supabase.auth.getUser(
    authHeader.replace("Bearer ", ""),
  );
  if (authErr || !user) return jsonErr("Unauthorized", 401);

  // Tier
  const { data: profile } = await supabase
    .from("profiles")
    .select("is_premium")
    .eq("id", user.id)
    .maybeSingle();
  const tier = profile?.is_premium ? "premium" : "free";
  const monthlyLimit = MONTHLY_LIMITS[tier] ?? 1;

  // Monthly quota
  const monthStart = new Date();
  monthStart.setDate(1);
  monthStart.setHours(0, 0, 0, 0);
  const monthKey = monthStart.toISOString().slice(0, 10);

  const { data: quota } = await supabase
    .from("breed_prediction_quota")
    .select("count")
    .eq("user_id", user.id)
    .eq("month", monthKey)
    .maybeSingle();

  if ((quota?.count ?? 0) >= monthlyLimit) {
    return json({ error: "RATE_LIMIT", limit: monthlyLimit, tier });
  }

  // Parse body
  const { photo_storage_path, pet_id, species, pet_name } = await req.json();
  if (!photo_storage_path || !species) return jsonErr("photo_storage_path ve species zorunlu.", 400);
  if (!["dog", "cat"].includes(species)) return jsonErr("species 'dog' veya 'cat' olmalı.", 400);

  // Fetch photo
  const { data: signedData } = await supabase.storage
    .from("breed-photos")
    .createSignedUrl(photo_storage_path, 300);
  if (!signedData?.signedUrl) return jsonErr("Fotoğraf yüklenemedi.", 500);

  const photoRes = await fetch(signedData.signedUrl);
  if (!photoRes.ok) return jsonErr("Fotoğraf okunamadı.", 500);
  const photoBuffer = await photoRes.arrayBuffer();
  const base64 = btoa(String.fromCharCode(...new Uint8Array(photoBuffer)));

  // Anthropic call
  const anthropic = new Anthropic({ apiKey: anthropicKey });
  let rawText = "";
  let inputTokens = 0;
  let outputTokens = 0;

  try {
    const speciesLabel = species === "dog" ? "köpek" : "kedi";
    const petLabel = pet_name ? `${pet_name} adlı ${speciesLabel}` : speciesLabel;

    const response = await anthropic.messages.create({
      model: "claude-sonnet-4-6",
      max_tokens: 800,
      system: SYSTEM_PROMPT,
      messages: [{
        role: "user",
        content: [
          { type: "image", source: { type: "base64", media_type: "image/jpeg", data: base64 } },
          { type: "text", text: `Bu ${petLabel} için cins tahmini yap.` },
        ],
      }],
    });

    rawText = response.content
      .filter((b) => b.type === "text")
      .map((b) => (b as { type: "text"; text: string }).text)
      .join("");

    inputTokens = response.usage.input_tokens;
    outputTokens = response.usage.output_tokens;
  } catch (err) {
    console.error("Anthropic error:", err);
    return jsonErr("Tahmin servisi şu an ulaşılamıyor.", 503);
  }

  // Detect special cases
  if (rawText.trim().startsWith("HUMAN_DETECTED")) {
    return json({ error: "HUMAN_DETECTED" });
  }
  if (rawText.trim().startsWith("POOR_QUALITY")) {
    return json({ error: "POOR_QUALITY" });
  }

  // Parse result
  const parsed = parseResult(rawText);
  if (!parsed) {
    // Fallback: return raw text
    return json({
      prediction_id: null,
      predictions: [],
      personality_notes: null,
      display_text: rawText.replace(/##[\s\S]*?##/g, "").trim(),
      raw: true,
    });
  }

  // Save to DB
  const { data: saved } = await supabase
    .from("breed_predictions")
    .insert({
      user_id: user.id,
      pet_id: pet_id ?? null,
      species,
      photo_url: photo_storage_path,
      predictions: parsed.predictions,
      personality_notes: parsed.personality,
      tokens_used: inputTokens + outputTokens,
    })
    .select("id")
    .single();

  // Update quota
  await supabase.from("breed_prediction_quota").upsert(
    { user_id: user.id, month: monthKey, count: (quota?.count ?? 0) + 1, tier },
    { onConflict: "user_id,month" },
  );

  return json({
    prediction_id: saved?.id,
    predictions: parsed.predictions,
    personality_notes: parsed.personality,
    display_text: parsed.display_text,
    quota: { used: (quota?.count ?? 0) + 1, limit: monthlyLimit, tier },
  });
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" },
  });
}

function jsonErr(msg: string, status = 400) {
  return json({ error: msg }, status);
}
