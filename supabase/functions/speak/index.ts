// The app's voice: text → ElevenLabs speech (MP3). The API key stays here, never in the app.
//
// POST { text: string }   200 audio/mpeg   400/502 { error, message }
//
// Uses the Flash model (lowest latency) and a small MP3 format, since phrases are short and
// played as soon as they arrive. The app caches every clip, so a phrase is only generated once.

import { corsHeaders, error, readJSON } from "../_shared/http.ts";

const MODEL = "eleven_flash_v2_5";
const MAX_CHARS = 600;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return error("bad_request", "Use POST.", 405);

  const body = await readJSON<{ text?: unknown }>(req);
  const text = typeof body?.text === "string" ? body.text.trim() : "";
  if (!text || text.length > MAX_CHARS) return error("bad_request", `Send text up to ${MAX_CHARS} characters.`, 400);

  const key = Deno.env.get("ELEVENLABS_API_KEY");
  const voice = Deno.env.get("ELEVENLABS_VOICE_ID") ?? "XrExE9yKIg1WjnnlVkGX";
  if (!key) return error("upstream_unavailable", "The voice isn't set up yet.", 503);

  try {
    const res = await fetch(
      `https://api.elevenlabs.io/v1/text-to-speech/${voice}/stream?output_format=mp3_22050_32`,
      {
        method: "POST",
        headers: { "xi-api-key": key, "Content-Type": "application/json" },
        body: JSON.stringify({
          text,
          model_id: MODEL,
          // Steady and clear rather than expressive; slightly quick, like a screen reader user expects.
          voice_settings: { stability: 0.6, similarity_boost: 0.8, speed: 1.05 },
        }),
        signal: AbortSignal.timeout(10000),
      },
    );
    if (!res.ok || !res.body) {
      console.error("ElevenLabs", res.status, await res.text());
      return error("upstream_unavailable", "The voice service isn't answering.", 502);
    }
    return new Response(res.body, {
      headers: { ...corsHeaders, "Content-Type": "audio/mpeg", "Cache-Control": "no-store" },
    });
  } catch (e) {
    console.error("speak failed", e);
    return error("upstream_unavailable", "The voice service isn't answering.", 502);
  }
});
