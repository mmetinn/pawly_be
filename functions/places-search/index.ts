import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const PLACES_API_BASE = "https://maps.googleapis.com/maps/api/place";
const RATE_LIMIT_PER_HOUR = 100;

interface NearbyRequest {
  type: "nearby";
  lat: number;
  lng: number;
  radius?: number; // meters, default 5000
  filters?: string[]; // "open_now" | "emergency" | "exotic" | "home_service"
}

interface TextRequest {
  type: "text";
  query: string;
  lat?: number;
  lng?: number;
}

interface DetailsRequest {
  type: "details";
  placeId: string;
}

type PlacesRequest = NearbyRequest | TextRequest | DetailsRequest;

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

  const apiKey = Deno.env.get("GOOGLE_PLACES_API_KEY");
  if (!apiKey) {
    return json({ error: "Places API not configured" }, 500);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const supabaseKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const supabase = createClient(supabaseUrl, supabaseKey);

  // Auth check
  const authHeader = req.headers.get("authorization");
  if (!authHeader) return json({ error: "Unauthorized" }, 401);
  const { data: { user }, error: authErr } = await supabase.auth.getUser(authHeader.replace("Bearer ", ""));
  if (authErr || !user) return json({ error: "Unauthorized" }, 401);

  // Rate limit: count searches in last hour
  const oneHourAgo = new Date(Date.now() - 3600_000).toISOString();
  const { count } = await supabase
    .from("vet_search_history")
    .select("id", { count: "exact", head: true })
    .eq("user_id", user.id)
    .gte("searched_at", oneHourAgo);

  if ((count ?? 0) >= RATE_LIMIT_PER_HOUR) {
    return json({ error: "Saatlik arama limitine ulaştınız. Lütfen biraz bekleyin." }, 429);
  }

  const body: PlacesRequest = await req.json();
  const commonParams = `key=${apiKey}&language=tr&region=tr`;

  try {
    if (body.type === "nearby") {
      const { lat, lng, radius = 5000, filters = [] } = body;
      let keyword = "veteriner";
      if (filters.includes("emergency")) keyword = "24 saat acil veteriner";
      else if (filters.includes("exotic")) keyword = "egzotik veteriner";
      else if (filters.includes("home_service")) keyword = "evde veteriner";

      const openNow = filters.includes("open_now") ? "&opennow=true" : "";
      const url = `${PLACES_API_BASE}/nearbysearch/json?location=${lat},${lng}&radius=${radius}&type=veterinary_care&keyword=${encodeURIComponent(keyword)}&${commonParams}${openNow}`;
      const res = await fetch(url);
      const data = await res.json();
      return json({ results: data.results ?? [], status: data.status });

    } else if (body.type === "text") {
      const { query, lat, lng } = body;
      const location = lat && lng ? `&location=${lat},${lng}&radius=50000` : "";
      const url = `${PLACES_API_BASE}/textsearch/json?query=${encodeURIComponent(query + " veteriner")}&type=veterinary_care&${commonParams}${location}`;
      const res = await fetch(url);
      const data = await res.json();
      return json({ results: data.results ?? [], status: data.status });

    } else if (body.type === "details") {
      const { placeId } = body;
      const fields = "place_id,name,formatted_address,formatted_phone_number,website,geometry,opening_hours,rating,user_ratings_total,photos,url";
      const url = `${PLACES_API_BASE}/details/json?place_id=${placeId}&fields=${fields}&${commonParams}`;
      const res = await fetch(url);
      const data = await res.json();
      return json({ result: data.result, status: data.status });
    }

    return json({ error: "Unknown request type" }, 400);
  } catch (err) {
    console.error("Places API error:", err);
    return json({ error: "Arama şu an yapılamıyor, lütfen tekrar deneyin." }, 503);
  }
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Access-Control-Allow-Origin": "*",
    },
  });
}
