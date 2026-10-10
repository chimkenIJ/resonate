// Search named places imported from the Georgia OSM extract, including partial names.
import { corsHeaders, error, isFiniteNumber, json, readJSON } from "../_shared/http.ts";
import { inGeorgia, OUTSIDE_GEORGIA_MESSAGE } from "../_shared/georgia.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return error("bad_request", "Use POST.", 405);
  const body = await readJSON<{ query?: unknown; latitude?: unknown; longitude?: unknown; limit?: unknown }>(req);
  const query = typeof body?.query === "string" ? body.query.trim() : "";
  const lat = body?.latitude, lon = body?.longitude;
  if (!query || query.length > 200 || !isFiniteNumber(lat) || !isFiniteNumber(lon)) {
    return error("bad_request", "Send query, latitude, and longitude.", 400);
  }
  if (!inGeorgia(lat, lon)) return error("outside_georgia", OUTSIDE_GEORGIA_MESSAGE, 422);
  const limit = isFiniteNumber(body?.limit) ? Math.min(Math.max(Math.round(body.limit), 1), 10) : 5;
  const base = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SUPABASE_ANON_KEY") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!base || !key) return error("upstream_unavailable", "Search isn't set up yet.", 503);

  try {
    const response = await fetch(`${base}/rest/v1/rpc/search_osm_places`, {
      method: "POST",
      headers: { apikey: key, Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
      body: JSON.stringify({ p_query: query, p_latitude: lat, p_longitude: lon, p_limit: limit }),
      signal: AbortSignal.timeout(8000),
    });
    if (!response.ok) throw new Error(`Place lookup ${response.status}`);
    const places = await response.json();
    if (!Array.isArray(places)) throw new Error("Invalid place lookup response");
    if (!places.length) return error("no_results", `I couldn't find ${query} near you. Try another place name.`, 404);
    return json({ places });
  } catch (e) {
    console.error("geocode lookup failed", e);
    return error("upstream_unavailable", "Search isn't working right now. Try again in a moment.", 502);
  }
});
