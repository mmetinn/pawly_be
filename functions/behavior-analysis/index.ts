/**
 * Behavior & Pattern Analysis Edge Function
 * Pro+ only. Aggregates data from all modules and generates AI insights.
 * LEGAL: "Pattern detection ve genel rehberliktir, tıbbi teşhis değildir."
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import Anthropic from "https://esm.sh/@anthropic-ai/sdk@0.27.3";

type AnalysisType =
  | "monthly_general" | "health_trends" | "feeding_pattern"
  | "activity_pattern" | "medication_adherence"
  | "concerning_changes" | "custom_question";

const MIN_DAYS = 14;
const MIN_RECORDS = 5;
const MAX_OUTPUT_TOKENS = 1500;

const SYSTEM_BASE = `Sen Pawly'nin AI veri analisti asistanısın. Evcil hayvan sahiplerinin tuttuğu günlük kayıtları (mama, egzersiz, ilaç, kilo, vet ziyaretleri) analiz ederek anlamlı pattern'ler ve içgörüler çıkarırsın.

KURالLAR:
1. Türkçe yanıt ver, sade ve anlaşılır dil kullan.
2. Veri olmayan alanlar için tahmin yapma — "Bu dönemde X kaydı yok" de.
3. KESİNLİKLE tıbbi teşhis koyma.
4. Pozitif bulgular öne çıkar, endişeleri dengeli sun.
5. Somut, actionable öneriler ver.
6. Yanıtının sonunda, görünmeyen JSON ekle:
##{"insights":[{"type":"positive|concern|recommendation","text":"...","severity":"low|medium|high"}],"has_urgent":false}##

YANIT FORMATI:
📊 ÖZET
[2-3 cümle genel değerlendirme]

✅ İYİ GİDEN
[maddeler]

⚠️ DİKKAT EDİLECEKLER
[maddeler, yoksa "Bu dönemde dikkat çeken olumsuz pattern yok" yaz]

💡 ÖNERİLER
[somut adımlar]

⚠️ Bu analiz bilgilendirme amaçlıdır, tıbbi teşhis değildir. Sağlık endişeleriniz için veterinerinize danışın.`;

const TYPE_PROMPTS: Record<AnalysisType, string> = {
  monthly_general: "Tüm modüllerdeki (mama, egzersiz, ilaç, kilo) son 30 günlük veriyi değerlendir. Genel sağlık tablosunu çiz.",
  health_trends: "Kilo değişimi, vet ziyaretleri ve genel sağlık göstergelerindeki uzun vadeli trendleri analiz et.",
  feeding_pattern: "Mama tüketim pattern'ini analiz et. Öğün düzeni, porsiyon tutarlılığı, iştah değişimleri.",
  activity_pattern: "Egzersiz ve aktivite pattern'ini analiz et. Haftalık dağılım, yoğunluk değişimleri, hedef uyumu.",
  medication_adherence: "İlaç takip verilerini analiz et. Uyum yüzdesi, atlanan günler, zamanlama pattern'leri.",
  concerning_changes: "Tüm modüllerde anormal veya endişe verici değişimleri tara. Keskin düşüşler, tutarsızlıklar, kötüleşen pattern'ler.",
  custom_question: "Kullanıcının sorusunu eldeki verilerle yanıtla.",
};

// ─── Data aggregator ──────────────────────────────────────────────────────────

async function aggregateData(
  supabase: ReturnType<typeof createClient>,
  petId: string,
  startDate: string,
  endDate: string,
  type: AnalysisType,
) {
  const summary: Record<string, unknown> = {};
  const warnings: string[] = [];

  // Pet info
  const { data: pet } = await supabase
    .from("pets")
    .select("name, species, breed, birth_date, weight_kg, is_neutered")
    .eq("id", petId)
    .maybeSingle();
  summary.pet = pet;

  // Feeding logs
  if (["monthly_general","feeding_pattern","concerning_changes"].includes(type)) {
    const { data: feedLogs } = await supabase
      .from("feeding_logs")
      .select("fed_at, amount_grams, meal_type, skipped")
      .eq("pet_id", petId)
      .gte("fed_at", startDate)
      .lte("fed_at", endDate + "T23:59:59")
      .order("fed_at", { ascending: false })
      .limit(200);

    if (!feedLogs || feedLogs.length < MIN_RECORDS) {
      warnings.push(`Beslenme kaydı yetersiz (${feedLogs?.length ?? 0} kayıt)`);
    }

    const skipped = feedLogs?.filter(f => f.skipped).length ?? 0;
    const total = feedLogs?.length ?? 0;
    const avgGrams = total > 0
      ? Math.round(feedLogs!.reduce((s, f) => s + (Number(f.amount_grams) || 0), 0) / total)
      : 0;

    summary.feeding = {
      total_logs: total,
      skipped_meals: skipped,
      skip_rate_pct: total > 0 ? Math.round((skipped / total) * 100) : 0,
      avg_grams_per_meal: avgGrams,
    };
  }

  // Exercise
  if (["monthly_general","activity_pattern","concerning_changes"].includes(type)) {
    const { data: exLogs } = await supabase
      .from("exercise_sessions")
      .select("session_date, duration_minutes, activity_type, distance_km")
      .eq("pet_id", petId)
      .gte("session_date", startDate)
      .lte("session_date", endDate)
      .order("session_date", { ascending: false })
      .limit(100);

    const totalMin = exLogs?.reduce((s, e) => s + (Number(e.duration_minutes) || 0), 0) ?? 0;
    const days = Math.max(1, Math.ceil((new Date(endDate).getTime() - new Date(startDate).getTime()) / 86400000));

    summary.exercise = {
      total_sessions: exLogs?.length ?? 0,
      total_minutes: totalMin,
      avg_minutes_per_day: Math.round(totalMin / days),
      activity_types: [...new Set(exLogs?.map(e => e.activity_type) ?? [])],
    };
  }

  // Medications
  if (["monthly_general","medication_adherence","concerning_changes"].includes(type)) {
    const { data: meds } = await supabase
      .from("medications")
      .select("name, is_active")
      .eq("pet_id", petId)
      .eq("is_active", true)
      .limit(10);

    if (meds && meds.length > 0) {
      const { data: medLogs } = await supabase
        .from("medication_logs")
        .select("status, logged_at")
        .eq("pet_id", petId)
        .gte("logged_at", startDate)
        .lte("logged_at", endDate + "T23:59:59")
        .limit(500);

      const given = medLogs?.filter(l => l.status === "given").length ?? 0;
      const skipped = medLogs?.filter(l => l.status === "skipped").length ?? 0;
      const total = (given + skipped) || 1;

      summary.medications = {
        active_count: meds.length,
        active_names: meds.map(m => m.name),
        adherence_pct: Math.round((given / total) * 100),
        given,
        skipped,
      };
    } else {
      summary.medications = { active_count: 0 };
    }
  }

  // Weight
  if (["monthly_general","health_trends","concerning_changes"].includes(type)) {
    const { data: weights } = await supabase
      .from("weight_records")
      .select("weight_kg, recorded_at, bcs_score")
      .eq("pet_id", petId)
      .gte("recorded_at", startDate)
      .lte("recorded_at", endDate)
      .order("recorded_at", { ascending: true })
      .limit(20);

    if (weights && weights.length >= 2) {
      const first = weights[0];
      const last = weights[weights.length - 1];
      summary.weight = {
        records: weights.length,
        start_kg: first.weight_kg,
        end_kg: last.weight_kg,
        delta_kg: Math.round((Number(last.weight_kg) - Number(first.weight_kg)) * 100) / 100,
        latest_bcs: last.bcs_score,
      };
    } else {
      summary.weight = { records: weights?.length ?? 0 };
    }
  }

  // Vet visits
  if (["monthly_general","health_trends"].includes(type)) {
    const { data: visits } = await supabase
      .from("vet_visits")
      .select("visit_date, visit_type, diagnosis")
      .eq("pet_id", petId)
      .gte("visit_date", startDate)
      .lte("visit_date", endDate)
      .order("visit_date", { ascending: false })
      .limit(10);

    summary.vet_visits = {
      count: visits?.length ?? 0,
      types: visits?.map(v => v.visit_type) ?? [],
    };
  }

  return { summary, warnings };
}

// ─── Main ─────────────────────────────────────────────────────────────────────

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

  // Pro+ check
  const { data: profile } = await supabase
    .from("profiles")
    .select("is_premium")
    .eq("id", user.id)
    .maybeSingle();
  if (!profile?.is_premium) return json({ error: "PRO_REQUIRED" }, 403);

  const { pet_id, analysis_type, start_date, end_date, custom_question } = await req.json();
  if (!pet_id || !analysis_type) return jsonErr("pet_id ve analysis_type zorunlu.", 400);

  const endDate = end_date ?? new Date().toISOString().slice(0, 10);
  const startDate = start_date ?? (() => {
    const d = new Date();
    d.setDate(d.getDate() - 30);
    return d.toISOString().slice(0, 10);
  })();

  // Data sufficiency check
  const daySpan = Math.ceil(
    (new Date(endDate).getTime() - new Date(startDate).getTime()) / 86400000,
  );
  if (daySpan < MIN_DAYS) {
    return json({ error: "INSUFFICIENT_DATA", reason: `En az ${MIN_DAYS} günlük veri gerekli.` });
  }

  // Aggregate data
  const { summary, warnings } = await aggregateData(
    supabase, pet_id, startDate, endDate, analysis_type as AnalysisType,
  );

  // Check if there's actually enough records
  const hasFeeding = (summary.feeding as { total_logs?: number })?.total_logs ?? 0;
  const hasExercise = (summary.exercise as { total_sessions?: number })?.total_sessions ?? 0;
  const hasMeds = (summary.medications as { given?: number })?.given ?? 0;
  const hasWeight = (summary.weight as { records?: number })?.records ?? 0;
  const totalRecords = hasFeeding + hasExercise + hasMeds + hasWeight;

  if (totalRecords < MIN_RECORDS && analysis_type !== "custom_question") {
    return json({
      error: "INSUFFICIENT_DATA",
      reason: "Anlamlı analiz için daha fazla günlük kayıt gerekli. Mama, egzersiz veya ilaç takibine devam edin.",
      total_records: totalRecords,
    });
  }

  // Build prompt
  const typePrompt = TYPE_PROMPTS[analysis_type as AnalysisType] ?? TYPE_PROMPTS.monthly_general;
  const petInfo = summary.pet as Record<string, unknown>;
  const petContext = petInfo
    ? `Pet: ${petInfo.name}, ${petInfo.species === "dog" ? "Köpek" : "Kedi"}${petInfo.breed ? `, ${petInfo.breed}` : ""}.`
    : "";

  const dataContext = `
ANALİZ PERİYODU: ${startDate} — ${endDate} (${daySpan} gün)

VERİ ÖZETİ:
${JSON.stringify(summary, null, 2)}

${warnings.length > 0 ? `UYARILAR: ${warnings.join(", ")}` : ""}
${custom_question ? `KULLANICI SORUSU: ${custom_question}` : ""}`;

  // Anthropic call
  const anthropic = new Anthropic({ apiKey: anthropicKey });
  let rawResponse = "";
  let inputTokens = 0;
  let outputTokens = 0;

  try {
    const response = await anthropic.messages.create({
      model: "claude-sonnet-4-6",
      max_tokens: MAX_OUTPUT_TOKENS,
      system: SYSTEM_BASE + "\n\n" + typePrompt,
      messages: [{ role: "user", content: petContext + "\n\n" + dataContext }],
    });
    rawResponse = response.content
      .filter(b => b.type === "text")
      .map(b => (b as { type: "text"; text: string }).text)
      .join("");
    inputTokens = response.usage.input_tokens;
    outputTokens = response.usage.output_tokens;
  } catch (err) {
    console.error("Anthropic error:", err);
    return jsonErr("Analiz servisi şu an ulaşılamıyor.", 503);
  }

  // Parse insights
  let keyInsights: unknown[] = [];
  let hasUrgent = false;

  const jsonMatch = rawResponse.match(/##(\{[\s\S]*?\})##/);
  if (jsonMatch) {
    try {
      const parsed = JSON.parse(jsonMatch[1]);
      keyInsights = parsed.insights ?? [];
      hasUrgent = parsed.has_urgent ?? false;
    } catch { /* keyword fallback */ }
  }

  // Keyword fallback for urgency
  if (!hasUrgent) {
    const lower = rawResponse.toLowerCase();
    hasUrgent = /acil|derhal|hemen vet|bugün vet/.test(lower);
  }

  const cleanResponse = rawResponse.replace(/##[\s\S]*?##/g, "").trim();
  const concernCount = keyInsights.filter(
    (i) => (i as { type: string }).type === "concern",
  ).length;

  // Save
  const { data: saved } = await supabase
    .from("behavior_analyses")
    .insert({
      user_id: user.id,
      pet_id,
      analysis_type,
      time_range_start: startDate,
      time_range_end: endDate,
      custom_question: custom_question ?? null,
      input_data_summary: summary,
      ai_response: cleanResponse,
      key_insights: keyInsights,
      concern_count: concernCount,
      has_urgent_finding: hasUrgent,
      tokens_used: inputTokens + outputTokens,
    })
    .select("id")
    .single();

  // Update subscription last_run_at
  await supabase
    .from("behavior_analysis_subscriptions")
    .update({ last_run_at: new Date().toISOString() })
    .eq("user_id", user.id)
    .eq("pet_id", pet_id)
    .eq("analysis_type", analysis_type);

  return json({
    analysis_id: saved?.id,
    ai_response: cleanResponse,
    key_insights: keyInsights,
    concern_count: concernCount,
    has_urgent_finding: hasUrgent,
    warnings,
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
