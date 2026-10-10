// Destination search on OpenStreetMap data, closest results first.
//
// With STADIA_API_KEY set (the cloud setup), searches Stadia Maps' hosted geocoder: the public
// Nominatim server blocks most requests from cloud servers. Otherwise uses NOMINATIM_URL.
//
// POST { query: string, latitude: number, longitude: number, limit?: number }
// 200  { places: [{ id, name, address, latitude, longitude, distance_m }] }
// 404  { error: "no_results" }   422 { error: "outside_georgia" }
//
// Nominatim ranks by importance, not distance, so we search near the user first, widen to all of
// Georgia if that finds too little, then sort by straight-line distance ourselves.

import { corsHeaders, error, isFiniteNumber, json, readJSON, upstream } from "../_shared/http.ts";
import { GEORGIA, haversine, inGeorgia, OUTSIDE_GEORGIA_MESSAGE } from "../_shared/georgia.ts";

interface GeocodeRequest {
  query?: unknown;
  latitude?: unknown;
  longitude?: unknown;
  limit?: unknown;
}

interface NominatimResult {
  osm_type: string;
  osm_id: number;
  lat: string;
  lon: string;
  name?: string;
  display_name: string;
  category?: string;
  type?: string;
  address?: Record<string, string>;
  namedetails?: Record<string, string>;
}

interface PlaceOut {
  id: string;
  name: string;
  address: string;
  latitude: number;
  longitude: number;
  distance_m: number;
}

/** About 15 km around the user. */
const NEARBY_DEGREES = 0.15;
/** When anything is closer than this, drop results beyond it (nobody walks 200 km). */
const FAR_M = 50_000;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return error("bad_request", "Use POST.", 405);

  const body = await readJSON<GeocodeRequest>(req);
  const query = typeof body?.query === "string" ? body.query.trim() : "";
  const lat = body?.latitude, lon = body?.longitude;
  if (!query || query.length > 200 || !isFiniteNumber(lat) || !isFiniteNumber(lon)) {
    return error("bad_request", "Send query, latitude, and longitude.", 400);
  }
  if (!inGeorgia(lat, lon)) return error("outside_georgia", OUTSIDE_GEORGIA_MESSAGE, 422);
  const limit = isFiniteNumber(body?.limit) ? Math.min(Math.max(Math.round(body.limit), 1), 10) : 5;

  const stadiaKey = Deno.env.get("STADIA_API_KEY");
  if (stadiaKey) {
    try {
      const sorted = (await stadiaSearch(stadiaKey, query, lat as number, lon as number))
        .filter((p) => inGeorgia(p.latitude, p.longitude))
        .sort((a, b) => a.distance_m - b.distance_m);
      const places = (sorted.some((p) => p.distance_m <= FAR_M) ? sorted.filter((p) => p.distance_m <= FAR_M) : sorted)
        .slice(0, limit);
      if (places.length === 0) {
        return error("no_results", `I couldn't find ${query} near you. Try saying it another way.`, 404);
      }
      return json({ places });
    } catch (e) {
      console.error("geocode (Stadia) failed", e);
      return error("upstream_unavailable", "Search isn't working right now. Try again in a moment.", 502);
    }
  }

  const base = Deno.env.get("NOMINATIM_URL");
  if (!base) return error("upstream_unavailable", "Search isn't set up yet.", 503);

  try {
    const nearby = await search(base, query, {
      west: Math.max(lon - NEARBY_DEGREES, GEORGIA.minLon),
      east: Math.min(lon + NEARBY_DEGREES, GEORGIA.maxLon),
      south: Math.max(lat - NEARBY_DEGREES, GEORGIA.minLat),
      north: Math.min(lat + NEARBY_DEGREES, GEORGIA.maxLat),
    });
    // The public OSM server allows one request per second; space out the second search.
    if (nearby.length < limit && base.includes("openstreetmap.org")) await new Promise((r) => setTimeout(r, 1100));
    const results = nearby.length >= limit
      ? nearby
      : dedupe([...nearby, ...await search(base, query, {
        west: GEORGIA.minLon, east: GEORGIA.maxLon, south: GEORGIA.minLat, north: GEORGIA.maxLat,
      })]);

    const sorted = results
      .filter(inGeorgiaState)
      .map((r) => toPlace(r, lat, lon))
      .filter((p) => inGeorgia(p.latitude, p.longitude))
      .sort((a, b) => a.distance_m - b.distance_m);
    const places = (sorted.some((p) => p.distance_m <= FAR_M) ? sorted.filter((p) => p.distance_m <= FAR_M) : sorted)
      .slice(0, limit);

    if (places.length === 0) {
      return error("no_results", `I couldn't find ${query} near you. Try saying it another way.`, 404);
    }
    return json({ places });
  } catch (e) {
    console.error("geocode upstream failed", e);
    return error("upstream_unavailable", "Search isn't working right now. Try again in a moment.", 502);
  }
});

async function search(
  base: string,
  query: string,
  box: { west: number; east: number; south: number; north: number },
): Promise<NominatimResult[]> {
  const params = new URLSearchParams({
    q: query,
    format: "jsonv2",
    addressdetails: "1",
    namedetails: "1",
    limit: "25",
    countrycodes: "us",
    viewbox: `${box.west},${box.north},${box.east},${box.south}`,
    bounded: "1",
    "accept-language": "en",
  });
  const res = await upstream(`${base.replace(/\/$/, "")}/search?${params}`);
  if (!res.ok) throw new Error(`Nominatim ${res.status}`);
  return await res.json() as NominatimResult[];
}

interface StadiaFeature {
  geometry: { coordinates: [number, number] };
  properties: {
    gid: string;
    name?: string;
    label?: string;
    housenumber?: string;
    street?: string;
    locality?: string;
    neighbourhood?: string;
    county?: string;
    region_a?: string;
  };
}

/** Stadia Maps geocoding (OSM data), biased toward the user and limited to Georgia. */
async function stadiaSearch(key: string, query: string, lat: number, lon: number): Promise<PlaceOut[]> {
  const params = new URLSearchParams({
    text: query,
    "focus.point.lat": String(lat),
    "focus.point.lon": String(lon),
    "boundary.rect.min_lat": String(GEORGIA.minLat),
    "boundary.rect.max_lat": String(GEORGIA.maxLat),
    "boundary.rect.min_lon": String(GEORGIA.minLon),
    "boundary.rect.max_lon": String(GEORGIA.maxLon),
    "boundary.country": "US",
    size: "25",
    lang: "en",
  });
  const res = await upstream(`https://api.stadiamaps.com/geocoding/v1/search?${params}`, {
    headers: { Authorization: `Stadia-Auth ${key}` },
  });
  if (!res.ok) throw new Error(`Stadia geocoding ${res.status}`);
  const data = await res.json() as { features?: StadiaFeature[] };
  return (data.features ?? [])
    // The box also covers parts of neighboring states.
    .filter((f) => !f.properties.region_a || f.properties.region_a === "GA")
    .map((f) => {
      const [longitude, latitude] = f.geometry.coordinates;
      const p = f.properties;
      const street = p.street ? [p.housenumber, p.street].filter(Boolean).join(" ") : "";
      const city = p.locality || p.neighbourhood || p.county || "";
      return {
        id: p.gid,
        name: p.name || p.label?.split(",")[0] || query,
        address: [street, city].filter(Boolean).join(", ") || p.label?.split(",").slice(1, 3).join(",").trim() || "",
        latitude,
        longitude,
        distance_m: Math.round(haversine(lat, lon, latitude, longitude)),
      };
    });
}

function dedupe(results: NominatimResult[]): NominatimResult[] {
  const seen = new Set<string>();
  return results.filter((r) => {
    const key = `${r.osm_type}:${r.osm_id}`;
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

/** The bounding box also covers parts of neighboring states; keep only the US state of Georgia. */
function inGeorgiaState(r: NominatimResult): boolean {
  const code = r.address?.["ISO3166-2-lvl4"];
  if (code) return code === "US-GA";
  const state = r.address?.state;
  return !state || state === "Georgia";
}

function toPlace(r: NominatimResult, userLat: number, userLon: number): PlaceOut {
  const latitude = Number(r.lat), longitude = Number(r.lon);
  const a = r.address ?? {};
  const name = r.namedetails?.name || r.name || r.display_name.split(",")[0];
  const street = a.road ? [a.house_number, a.road].filter(Boolean).join(" ") : "";
  const city = a.city || a.town || a.village || a.suburb || a.county || "";
  const address = [street, city].filter(Boolean).join(", ") || r.display_name.split(",").slice(1, 3).join(",").trim();
  return {
    id: `osm:${r.osm_type}:${r.osm_id}`,
    name,
    address,
    latitude,
    longitude,
    distance_m: Math.round(haversine(userLat, userLon, latitude, longitude)),
  };
}
