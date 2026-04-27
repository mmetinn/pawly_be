// Deploy: npx supabase functions deploy revenuecat-webhook --no-verify-jwt
// --no-verify-jwt is required because RevenueCat sends its own bearer token, not a Supabase JWT.
import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const WEBHOOK_AUTH_TOKEN = Deno.env.get("REVENUECAT_WEBHOOK_AUTH_TOKEN")!;

const ACTIVE_TYPES = new Set([
  "INITIAL_PURCHASE",
  "RENEWAL",
  "NON_RENEWING_PURCHASE",
  "PRODUCT_CHANGE",
  "UNCANCELLATION",
  "TRANSFER",
]);

const INACTIVE_TYPES = new Set([
  "CANCELLATION",
  "EXPIRATION",
  "REFUND",
  "SUBSCRIPTION_PAUSED",
]);

Deno.serve(async (req) => {
  const auth = req.headers.get("authorization");
  if (auth !== `Bearer ${WEBHOOK_AUTH_TOKEN}`) {
    return new Response("Unauthorized", { status: 401 });
  }

  // deno-lint-ignore no-explicit-any
  const body = await req.json().catch(() => null) as any;
  if (!body?.event) {
    return new Response("Bad request", { status: 400 });
  }

  const event = body.event;
  const type: string = event.type;
  const appUserId: string | undefined = event.app_user_id;
  const productId: string | undefined = event.product_id;
  const transactionId: string | undefined = event.transaction_id ?? event.original_transaction_id;
  const purchasedAtMs: number | undefined = event.purchased_at_ms;
  const expirationAtMs: number | undefined = event.expiration_at_ms;
  const store: string | undefined = event.store; // 'APP_STORE' | 'PLAY_STORE'

  if (!appUserId) {
    return new Response("Missing app_user_id", { status: 400 });
  }

  const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { persistSession: false },
  });

  const platform = store === "APP_STORE" ? "ios" : store === "PLAY_STORE" ? "android" : null;

  let isPremium: boolean | null = null;
  if (ACTIVE_TYPES.has(type)) isPremium = true;
  if (INACTIVE_TYPES.has(type)) isPremium = false;

  if (isPremium !== null) {
    // Backward compat: update profiles.is_premium
    const update: Record<string, unknown> = { is_premium: isPremium };
    if (isPremium) {
      update.premium_purchased_at = purchasedAtMs
        ? new Date(purchasedAtMs).toISOString()
        : new Date().toISOString();
    }
    const { error: profileErr } = await supabase.from("profiles").update(update).eq("id", appUserId);
    if (profileErr) console.error("profiles update error:", profileErr);

    // New tier system
    const newTier = isPremium ? "premium" : "free";
    const subSource = store === "APP_STORE" ? "app_store" : store === "PLAY_STORE" ? "play_store" : "manual";

    if (isPremium) {
      const { error: subErr } = await supabase.from("user_subscriptions").upsert({
        user_id: appUserId,
        tier_key: newTier,
        status: "active",
        source: subSource,
        external_subscription_id: transactionId ?? null,
        started_at: purchasedAtMs ? new Date(purchasedAtMs).toISOString() : new Date().toISOString(),
        expires_at: expirationAtMs ? new Date(expirationAtMs).toISOString() : null,
        last_verified_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
      }, { onConflict: "user_id" });
      if (subErr) console.error("user_subscriptions upsert error:", subErr);

      // Log tier change
      const { data: existing } = await supabase
        .from("user_subscriptions")
        .select("tier_key")
        .eq("user_id", appUserId)
        .maybeSingle();

      if ((existing as Record<string, unknown>)?.tier_key !== newTier) {
        await supabase.from("tier_change_history").insert({
          user_id: appUserId,
          from_tier: (existing as Record<string, unknown>)?.tier_key ?? "free",
          to_tier: newTier,
          reason: "upgrade",
          metadata: { event_type: type, product_id: productId, transaction_id: transactionId },
        });
      }
    } else {
      // Downgrade to free
      await supabase.from("user_subscriptions").upsert({
        user_id: appUserId,
        tier_key: "free",
        status: INACTIVE_TYPES.has(type) && type === "REFUND" ? "cancelled" : "expired",
        source: "free",
        expires_at: null,
        cancelled_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
      }, { onConflict: "user_id" });

      await supabase.from("tier_change_history").insert({
        user_id: appUserId,
        from_tier: "premium",
        to_tier: "free",
        reason: type === "REFUND" ? "refund" : "expiration",
        metadata: { event_type: type },
      });
    }
  }

  // Audit log for active purchase events
  if (ACTIVE_TYPES.has(type) && productId && transactionId && platform) {
    const { error } = await supabase.from("purchases").upsert(
      {
        user_id: appUserId,
        product_id: productId,
        platform,
        transaction_id: transactionId,
        purchased_at: purchasedAtMs
          ? new Date(purchasedAtMs).toISOString()
          : new Date().toISOString(),
        expires_at: expirationAtMs ? new Date(expirationAtMs).toISOString() : null,
        raw_payload: body,
      },
      { onConflict: "platform,transaction_id" }
    );
    if (error) console.error("purchases upsert error:", error);
  }

  return new Response("OK", { status: 200 });
});
