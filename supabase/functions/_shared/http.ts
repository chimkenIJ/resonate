// Shared request/response helpers for Resonate Edge Functions.

export const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

/** Error codes the app maps to spoken messages (see AppError in the iOS app). */
export type ErrorCode = "bad_request" | "outside_georgia" | "no_results" | "no_route" | "upstream_unavailable";

export function error(code: ErrorCode, message: string, status: number): Response {
  return json({ error: code, message }, status);
}

export async function readJSON<T>(req: Request): Promise<T | null> {
  try {
    return (await req.json()) as T;
  } catch {
    return null;
  }
}

export function isFiniteNumber(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value);
}

/** Fetches from the self-hosted map server with the shared gateway key. */
export async function upstream(url: string, init: RequestInit = {}, timeoutMs = 15000): Promise<Response> {
  const headers = new Headers(init.headers);
  const key = Deno.env.get("RESONATE_UPSTREAM_KEY");
  if (key) headers.set("X-Resonate-Key", key);
  const agent = Deno.env.get("UPSTREAM_USER_AGENT");
  if (agent) headers.set("User-Agent", agent);
  return await fetch(url, { ...init, headers, signal: AbortSignal.timeout(timeoutMs) });
}
