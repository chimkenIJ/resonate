// Accessible walking route: Valhalla pedestrian costing on Georgia OSM data, then the route is
// checked against OSM accessibility features (curb ramps, tactile paving, audio signals, steps).
//
// POST {
//   origin: { latitude, longitude },
//   destination: { latitude, longitude, name? },
//   preferences?: { avoid_steps?, max_incline?, prefer_tactile_paving?, prefer_audio_signals? }
// }
// 200  { route: { duration_s, distance_m, is_step_free, relaxed, polyline, steps, features, avoided, hazards, entrance } }
//
// When OSM maps an entrance near the destination, the route ends at that door (main entrance
// first) instead of the middle of the building, and `entrance` describes it.
// 404  { error: "no_route" }   422 { error: "outside_georgia" }

import { corsHeaders, error, isFiniteNumber, json, readJSON, upstream } from "../_shared/http.ts";
import { haversine, inGeorgia, OUTSIDE_GEORGIA_MESSAGE } from "../_shared/georgia.ts";
import { decodePolyline6 } from "../_shared/polyline.ts";

interface Point { latitude?: unknown; longitude?: unknown; name?: unknown }
interface Preferences {
  avoid_steps?: boolean;
  max_incline?: number;
  prefer_tactile_paving?: boolean;
  prefer_audio_signals?: boolean;
}
interface RouteRequest { origin?: Point; destination?: Point; preferences?: Preferences }

interface ValhallaManeuver {
  type: number;
  instruction: string;
  verbal_pre_transition_instruction?: string;
  verbal_transition_alert_instruction?: string;
  length: number; // miles (directions are in US units, so spoken text says feet and miles)
  time: number;
  begin_shape_index: number;
}
interface ValhallaTrip {
  summary: { length: number; time: number };
  legs: { shape: string; maneuvers: ValhallaManeuver[] }[];
}
interface AccessFeature {
  kind: string;
  osm_id: number;
  latitude: number;
  longitude: number;
  fraction: number;
  distance_m: number;
}

const METERS_PER_MILE = 1609.344;

interface RouteEdge { use: string; begin_shape_index: number }
interface Entrance { latitude: number; longitude: number; entrance: string | null; door: string | null; distance_m: number }

/** Valhalla maneuver type → app Maneuver raw value. */
function maneuverName(type: number): string {
  switch (type) {
    case 1: case 2: case 3: return "depart";
    case 4: case 5: case 6: return "arrive";
    case 9: case 23: return "slightRight";
    case 10: case 18: case 20: return "right";
    case 11: return "sharpRight";
    case 12: case 13: return "uTurn";
    case 14: return "sharpLeft";
    case 15: case 19: case 21: return "left";
    case 16: case 24: return "slightLeft";
    case 39: return "elevator";
    case 40: return "steps";
    default: return "straight";
  }
}

function costing(prefs: Preferences, relaxed: boolean) {
  const avoidSteps = prefs.avoid_steps ?? true;
  const maxGrade = Math.round(Math.min(Math.max(prefs.max_incline ?? 0.08, 0.02), 0.3) * 100);
  return {
    pedestrian: {
      // Valhalla's mode for blind and low-vision walkers: instructions name landmarks you can
      // confirm with a cane ("Pass the gate", "Pass Atlantic Drive") instead of "the walkway".
      type: "blind",
      // A large penalty instead of a hard ban, so a route still exists when steps can't be avoided.
      step_penalty: avoidSteps && !relaxed ? 3600 : 30,
      max_grade: relaxed ? 90 : maxGrade,
      use_hills: 0.1,
      // Prefer sidewalks and footpaths; avoid alleys and driveways, which rarely have curb cuts.
      walkway_factor: 0.8,
      sidewalk_factor: 0.7,
      alley_factor: 3,
      driveway_factor: 5,
      use_ferry: 0,
      use_tracks: 0,
      use_living_streets: 0.6,
      max_hiking_difficulty: 1,
    },
  };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return error("bad_request", "Use POST.", 405);

  const body = await readJSON<RouteRequest>(req);
  const o = body?.origin, d = body?.destination;
  if (!isFiniteNumber(o?.latitude) || !isFiniteNumber(o?.longitude) || !isFiniteNumber(d?.latitude) || !isFiniteNumber(d?.longitude)) {
    return error("bad_request", "Send origin and destination coordinates.", 400);
  }
  const origin = { lat: o.latitude as number, lon: o.longitude as number };
  let dest = { lat: d.latitude as number, lon: d.longitude as number };
  if (!inGeorgia(origin.lat, origin.lon) || !inGeorgia(dest.lat, dest.lon)) {
    return error("outside_georgia", OUTSIDE_GEORGIA_MESSAGE, 422);
  }
  if (haversine(origin.lat, origin.lon, dest.lat, dest.lon) > 40_000) {
    return error("no_route", "That's more than 25 miles away, too far to walk. Try somewhere closer.", 404);
  }

  const base = Deno.env.get("VALHALLA_URL");
  if (!base) return error("upstream_unavailable", "Routing isn't set up yet.", 503);
  const prefs = body?.preferences ?? {};

  try {
    // End at the building's door when OSM knows where it is.
    const entrance = (await rpc<Entrance[]>("nearest_entrance", { p_latitude: dest.lat, p_longitude: dest.lon, p_radius_m: 45 }))?.[0] ?? null;
    if (entrance) dest = { lat: entrance.latitude, lon: entrance.longitude };

    let relaxed = false;
    let trip = await valhallaRoute(base, origin, dest, prefs, false);
    if (!trip) {
      // Nothing meets the strict settings (for example, the only way in has steps). Try again
      // without them, and tell the user the route isn't step-free.
      relaxed = true;
      trip = await valhallaRoute(base, origin, dest, prefs, true);
    }
    if (!trip) return error("no_route", "I couldn't find a walking route there.", 404);

    const leg = trip.legs[0];
    const shape = decodePolyline6(leg.shape);
    const uses = await edgeUses(base, leg.shape, prefs, relaxed);
    const lineString = { type: "LineString", coordinates: shape.map(([la, lo]) => [lo, la]) };
    const [access, avoidedSteps] = await Promise.all([
      rpc<AccessFeature[]>("route_access_features", { p_route: lineString, p_buffer_m: 8 }),
      prefs.avoid_steps === false ? Promise.resolve([]) : rpc<{ latitude: number; longitude: number }[]>(
        "route_avoided_steps", { p_route: lineString },
      ),
    ]);

    // Valhalla knows exactly which edges of the route are stairs; OSM steps near the line are
    // often staircases branching off the sidewalk, which the route doesn't climb.
    const stepEdges = uses.filter((e) => e.use === "steps");
    // One staircase can span several edges and also gets its own "Take the stairs" maneuver,
    // so count staircases as runs of consecutive step edges.
    const stepsOnRoute = Math.max(
      uses.filter((e, i) => e.use === "steps" && uses[i - 1]?.use !== "steps").length,
      leg.maneuvers.filter((m) => m.type === 40).length,
    );
    const count = (kind: string) => (access ?? []).filter((f) => f.kind === kind).length;

    const steps = leg.maneuvers.map((m) => {
      const [latitude, longitude] = shape[Math.min(m.begin_shape_index, shape.length - 1)];
      const note = crossingNote(access ?? [], latitude, longitude);
      const spoken = m.verbal_pre_transition_instruction ?? m.instruction;
      return {
        instruction: m.instruction.replace(/\.$/, ""),
        spoken_instruction: note ? `${spoken} ${note}` : spoken,
        alert_instruction: m.verbal_transition_alert_instruction ?? null,
        distance_m: Math.round(m.length * METERS_PER_MILE),
        maneuver: maneuverName(m.type),
        shape_index: Math.min(m.begin_shape_index, shape.length - 1),
        latitude,
        longitude,
      };
    });

    const crossings = count("crossing");
    const curbInfo = count("curb_ramp") + count("raised_curb");
    const features = [
      { kind: "curb_ramps", count: count("curb_ramp") },
      { kind: "audio_crossings", count: count("audio_signal") },
      { kind: "tactile_paving", count: count("tactile_paving") },
      { kind: "elevators", count: count("elevator") + uses.filter((e) => e.use === "elevator").length },
      { kind: "steps", count: stepsOnRoute },
      { kind: "raised_curbs", count: count("raised_curb") },
      // Crossings with no kerb tag in OSM: we can't promise a curb ramp there.
      { kind: "unverified_curbs", count: access === null ? 1 : Math.max(crossings - curbInfo, 0) },
    ].filter((f) => f.count > 0);

    return json({
      route: {
        duration_s: Math.round(trip.summary.time),
        distance_m: Math.round(trip.summary.length * METERS_PER_MILE),
        is_step_free: stepsOnRoute === 0,
        relaxed,
        polyline: shape,
        steps,
        features,
        // Only claim stairs were avoided when the route really has none.
        avoided: stepsOnRoute > 0 ? [] : spreadOut(avoidedSteps ?? [], 25, 2)
          .map((s) => ({ label: "Stairs avoided", latitude: s.latitude, longitude: s.longitude })),
        hazards: [
          ...(access ?? [])
            .filter((f) => f.kind === "raised_curb")
            .map(({ kind, latitude, longitude, fraction }) => ({ kind, latitude, longitude, fraction })),
          ...stepEdges.map((e) => {
            const index = Math.min(e.begin_shape_index, shape.length - 1);
            const [latitude, longitude] = shape[index];
            return { kind: "steps", latitude, longitude, fraction: index / Math.max(shape.length - 1, 1) };
          }),
        ].sort((a, b) => a.fraction - b.fraction),
        // Street crossings on the route, so walk signals are only read out where the user will cross.
        crossings: (access ?? [])
          .filter((f) => f.kind === "crossing" && f.distance_m <= 6)
          .map(({ latitude, longitude, fraction }) => ({ latitude, longitude, fraction })),
        entrance: entrance
          ? { latitude: entrance.latitude, longitude: entrance.longitude, is_main: entrance.entrance === "main", door: entrance.door }
          : null,
      },
    });
  } catch (e) {
    console.error("route failed", e);
    return error("upstream_unavailable", "Routing isn't working right now. Try again in a moment.", 502);
  }
});

/**
 * Valhalla runs either self-hosted (VALHALLA_URL only, e.g. the Docker container on the Mac) or on
 * Stadia Maps' hosted Valhalla (VALHALLA_URL=https://api.stadiamaps.com plus VALHALLA_API_KEY), which
 * takes the same requests at versioned paths.
 */
function valhallaEndpoint(base: string, action: "route" | "trace_attributes"): string {
  const root = base.replace(/\/$/, "");
  return Deno.env.get("VALHALLA_API_KEY") ? `${root}/${action}/v1` : `${root}/${action}`;
}

function valhallaHeaders(): HeadersInit {
  const key = Deno.env.get("VALHALLA_API_KEY");
  return key
    ? { "Content-Type": "application/json", Authorization: `Stadia-Auth ${key}` }
    : { "Content-Type": "application/json" };
}

async function valhallaRoute(
  base: string,
  origin: { lat: number; lon: number },
  dest: { lat: number; lon: number },
  prefs: Preferences,
  relaxed: boolean,
): Promise<ValhallaTrip | null> {
  const res = await upstream(valhallaEndpoint(base, "route"), {
    method: "POST",
    headers: valhallaHeaders(),
    body: JSON.stringify({
      locations: [
        { lat: origin.lat, lon: origin.lon, type: "break" },
        { lat: dest.lat, lon: dest.lon, type: "break" },
      ],
      costing: "pedestrian",
      costing_options: costing(prefs, relaxed),
      directions_options: { units: "miles", language: "en-US" },
    }),
  });
  if (res.status === 400) return null; // Valhalla: no path for these settings
  if (!res.ok) throw new Error(`Valhalla route ${res.status}: ${await res.text()}`);
  return ((await res.json()) as { trip: ValhallaTrip }).trip;
}

/** OSM `use` of every edge on the route (sidewalk, footway, steps, elevator, crossing, ...). */
async function edgeUses(base: string, encodedShape: string, prefs: Preferences, relaxed: boolean): Promise<RouteEdge[]> {
  try {
    const res = await upstream(valhallaEndpoint(base, "trace_attributes"), {
      method: "POST",
      headers: valhallaHeaders(),
      body: JSON.stringify({
        encoded_polyline: encodedShape,
        shape_match: "edge_walk",
        costing: "pedestrian",
        costing_options: costing(prefs, relaxed),
        filters: { attributes: ["edge.use", "edge.begin_shape_index"], action: "include" },
      }),
    });
    if (!res.ok) return [];
    const data = (await res.json()) as { edges?: { use?: string; begin_shape_index?: number }[] };
    return (data.edges ?? []).map((e) => ({ use: e.use ?? "", begin_shape_index: e.begin_shape_index ?? 0 }));
  } catch {
    return [];
  }
}

/** Calls a Postgres function through PostgREST. Returns null if the lookup fails. */
async function rpc<T>(name: string, args: Record<string, unknown>): Promise<T | null> {
  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SUPABASE_ANON_KEY") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !key) return null;
  try {
    const res = await fetch(`${url}/rest/v1/rpc/${name}`, {
      method: "POST",
      headers: { apikey: key, Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
      body: JSON.stringify(args),
      signal: AbortSignal.timeout(8000),
    });
    if (!res.ok) {
      console.error(`rpc ${name} ${res.status}`, await res.text());
      return null;
    }
    return (await res.json()) as T;
  } catch (e) {
    console.error(`rpc ${name} failed`, e);
    return null;
  }
}

/** Keeps at most `max` points, each at least `minM` meters from the ones already kept. */
function spreadOut<T extends { latitude: number; longitude: number }>(points: T[], minM: number, max: number): T[] {
  const kept: T[] = [];
  for (const p of points) {
    if (kept.length >= max) break;
    if (kept.every((k) => haversine(k.latitude, k.longitude, p.latitude, p.longitude) >= minM)) kept.push(p);
  }
  return kept;
}

/** A spoken note when a turn happens at a crossing with an audio signal or tactile paving. */
function crossingNote(features: AccessFeature[], lat: number, lon: number): string | null {
  const near = features.filter((f) => haversine(lat, lon, f.latitude, f.longitude) < 15);
  const parts: string[] = [];
  if (near.some((f) => f.kind === "audio_signal")) parts.push("The crossing here has an audio signal.");
  if (near.some((f) => f.kind === "raised_curb")) parts.push("Careful, the curb here is raised.");
  else if (near.some((f) => f.kind === "curb_ramp")) parts.push("There's a curb ramp.");
  if (near.some((f) => f.kind === "tactile_paving")) parts.push("Tactile paving marks the edge.");
  return parts.length ? parts.join(" ") : null;
}
