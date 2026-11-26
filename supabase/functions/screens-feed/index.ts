// screens-feed — the office TV screens' live numbers (migration 0163).
//
// GET with header `x-screen-key: <key>`. The key is minted per TV or office (see the runbook note in
// 0163 and README), stored only as a SHA-256 hash in screen_keys, and revoked by setting revoked_at.
// No key, a wrong key or a revoked key gets 401 and no data: this is not the public dashboard that
// was retired on 03/11/2026.
//
// Serves screens_feed(): billing by consultant (YTD and this quarter, with targets), deals at Offered,
// and the newest open roles by company. No candidate, contact or deal-level data.
//
// The TVs poll every few minutes, so the result is cached in memory for 60 seconds per instance and
// last_used_at is written at most every 10 minutes per key (Free plan log and write budget, 0152).
import { createClient } from "jsr:@supabase/supabase-js@2";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

const CACHE_MS = 60_000;
const TOUCH_MS = 10 * 60_000;

let cache: { at: number; body: string } | null = null;
const touched = new Map<string, number>();

// Any origin: the screen key is the gate, not CORS. A key holder could call the feed from curl
// anyway, and this lets the TV page move hosts (26/11/2026: moving to a new Netlify site) without a
// redeploy here. No cookies or credentials are involved, so "*" grants nothing extra.
function corsFor(_req: Request): Record<string, string> {
  return {
    "Content-Type": "application/json",
    "Cache-Control": "no-store",
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "x-screen-key",
    "Access-Control-Allow-Methods": "GET, OPTIONS",
  };
}

async function sha256hex(s: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function json(body: unknown, status: number, headers: Record<string, string>): Response {
  return new Response(typeof body === "string" ? body : JSON.stringify(body), { status, headers });
}

Deno.serve(async (req) => {
  const headers = corsFor(req);
  if (req.method === "OPTIONS") return new Response(null, { headers });
  if (req.method !== "GET") return json({ error: "GET only" }, 405, headers);

  const key = (req.headers.get("x-screen-key") ?? "").trim();
  if (key.length < 32 || key.length > 200) return json({ error: "screen key required" }, 401, headers);

  const hash = await sha256hex(key);
  const { data: row, error: kerr } = await db.from("screen_keys").select("id, revoked_at").eq("key_hash", hash).maybeSingle();
  if (kerr) return json({ error: "unavailable" }, 503, headers);
  if (!row || row.revoked_at) return json({ error: "screen key not recognised" }, 401, headers);

  const now = Date.now();
  if ((touched.get(row.id) ?? 0) < now - TOUCH_MS) {
    touched.set(row.id, now);
    db.from("screen_keys").update({ last_used_at: new Date(now).toISOString() }).eq("id", row.id).then(() => {});
  }

  if (!cache || cache.at < now - CACHE_MS) {
    const { data, error } = await db.rpc("screens_feed");
    if (error) return json({ error: "feed unavailable" }, 503, headers);
    cache = { at: now, body: JSON.stringify(data) };
  }
  return json(cache.body, 200, headers);
});
