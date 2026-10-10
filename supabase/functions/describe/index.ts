// "Describe the whole scene" / "Describe room": a camera photo → a short spoken description
// from Gemini. The API key stays here. Photos are not stored.
//
// POST { image_base64: string (JPEG), setting: "outdoor" | "indoor" }
// 200  { description: string }

import { corsHeaders, error, json, readJSON } from "../_shared/http.ts";

const MAX_IMAGE_BYTES = 3_000_000;

const PROMPTS: Record<string, string> = {
  outdoor:
    "You describe surroundings for a blind person holding a phone camera at chest height, outdoors. " +
    "In 2 or 3 short spoken sentences: first anything that could be a hazard in their path (curbs, poles, " +
    "steps, vehicles, people, construction), then the layout, using left, right, ahead and approximate meters. " +
    "Read important signs or text. Describe only what is visible in this snapshot. Plain words, no preamble, never mention Gemini, AI, or 'the image shows'.",
  indoor:
    "You describe a room for a blind person holding a phone camera at chest height. " +
    "In 2 or 3 short spoken sentences: first anything in their path, then the room's layout and where the " +
    "doors are, using left, right, ahead and approximate meters or steps. Read important signs or labels. " +
    "Describe only what is visible in this snapshot. Plain words, no preamble, never mention Gemini, AI, or 'the image shows'.",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return error("bad_request", "Use POST.", 405);

  const body = await readJSON<{ image_base64?: unknown; setting?: unknown }>(req);
  const image = typeof body?.image_base64 === "string" ? body.image_base64 : "";
  const setting = body?.setting === "indoor" ? "indoor" : "outdoor";
  if (!image || image.length > MAX_IMAGE_BYTES * 1.4) return error("bad_request", "Send a JPEG photo.", 400);

  const key = Deno.env.get("GEMINI_API_KEY");
  const model = Deno.env.get("GEMINI_MODEL") ?? "gemini-3.5-flash-lite";
  if (!key) return error("upstream_unavailable", "Descriptions aren't set up yet.", 503);

  try {
    const res = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`, {
      method: "POST",
      headers: { "x-goog-api-key": key, "Content-Type": "application/json" },
      body: JSON.stringify({
        contents: [{ parts: [{ text: PROMPTS[setting] }, { inline_data: { mime_type: "image/jpeg", data: image } }] }],
        // Minimal thinking keeps answers to ~2 seconds and stops thinking from eating the reply.
        generationConfig: { maxOutputTokens: 400, temperature: 0.3, thinkingConfig: { thinkingLevel: "minimal" } },
      }),
      signal: AbortSignal.timeout(20000),
    });
    if (!res.ok) {
      console.error("Gemini", res.status, await res.text());
      return error("upstream_unavailable", "I couldn't describe the scene right now.", 502);
    }
    const data = await res.json() as { candidates?: { content?: { parts?: { text?: string }[] } }[] };
    const text = data.candidates?.[0]?.content?.parts?.map((p) => p.text ?? "").join("").trim();
    if (!text) return error("upstream_unavailable", "I couldn't make out the scene. Try pointing the phone ahead.", 502);
    return json({ description: text });
  } catch (e) {
    console.error("describe failed", e);
    return error("upstream_unavailable", "I couldn't describe the scene right now.", 502);
  }
});
