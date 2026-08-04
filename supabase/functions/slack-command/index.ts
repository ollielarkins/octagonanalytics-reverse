// slack-command — Slack slash-command endpoint for /dashboard.
// One-way webhooks can't answer commands, so this is a request endpoint Slack POSTs
// to. It verifies Slack's signing secret (only your workspace can call it), then
// returns the live dashboard (same data Claude shows), visible to the whole channel.
//
// Setup (admin):
//   1. Supabase secret: SLACK_SIGNING_SECRET = your Slack app's Signing Secret.
//   2. Slack app -> Slash Commands -> /dashboard, Request URL =
//      https://kzcmssldvtjnbwwunuwm.supabase.co/functions/v1/slack-command
// Deployed verify_jwt=false (Slack can't send a Supabase JWT); auth is the Slack signature.
import { createClient } from "jsr:@supabase/supabase-js@2";
const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

async function hmacHex(secret: string, msg: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(msg));
  return Array.from(new Uint8Array(sig)).map((b) => b.toString(16).padStart(2, "0")).join("");
}
function timingEq(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let r = 0; for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}
const gbp = (n: any) => "£" + Math.round(Number(n) || 0).toLocaleString("en-GB");
const num = (n: any) => (Number(n) || 0).toLocaleString("en-GB");

function formatDashboard(D: any): string {
  const k = D.kpis ?? {}, f = D.funnel ?? {}, h = D.health ?? {};
  const conv = k.cv_2026 ? ((k.placed_2026 / k.cv_2026) * 100).toFixed(1) + "%" : "—";
  const gen = String(D.generated_at ?? "").slice(0, 16).replace("T", " ");
  const top = (D.consultants ?? []).slice(0, 3).map((c: any) => `${c.name} ${c.cv_sent}`).join(" · ") || "—";
  const stale = h.overall && h.overall !== "ok"
    ? `  :warning: *sync ${h.overall}* — figures may be stale`
    : "";
  return [
    `*Octagon dashboard* — as of ${gen} UTC · sync: ${h.overall ?? "?"}${stale}`,
    `*KPIs (2026):* ${num(k.cv_2026)} CVs · ${num(k.placed_2026)} placed (${conv} CV→placed) · ${num(k.candidates)} candidates · ${num(k.open_jobs)}/${num(k.jobs)} open jobs · ${num(k.clients)} clients · ${num(k.consultants)} consultants`,
    `*2026 funnel:* CV ${num(f.cv_sent)} → IR ${num(f.interview_request)} → 1st ${num(f.first_interview)} → 2nd ${num(f.second_interview)} → 3rd ${num(f.third_interview)} → Offer ${num(f.offered)} → Placed ${num(f.placed)}`,
    `*Top consultants (CVs):* ${top}`,
    `*Pipeline:* open ${gbp(k.open_pipeline)} · won ${gbp(k.won)}`,
  ].join("\n");
}

Deno.serve(async (req) => {
  if (req.method === "GET") return new Response(JSON.stringify({ name: "octagon-slack-command", ok: true }), { headers: { "Content-Type": "application/json" } });
  if (req.method !== "POST") return new Response("method not allowed", { status: 405 });

  const secret = Deno.env.get("SLACK_SIGNING_SECRET");
  if (!secret) return new Response(JSON.stringify({ text: "Slack command endpoint isn't configured: SLACK_SIGNING_SECRET is not set." }), { status: 200, headers: { "Content-Type": "application/json" } });

  const raw = await req.text();
  const ts = req.headers.get("x-slack-request-timestamp") ?? "";
  const sig = req.headers.get("x-slack-signature") ?? "";
  if (!ts || Math.abs(Date.now() / 1000 - Number(ts)) > 300) return new Response("stale or missing timestamp", { status: 401 });
  const expected = "v0=" + await hmacHex(secret, `v0:${ts}:${raw}`);
  if (!timingEq(expected, sig)) return new Response("bad signature", { status: 401 });

  // Verified as a genuine Slack request. Return the dashboard.
  const { data, error } = await db.rpc("dashboard_json");
  const text = error ? `Couldn't load the dashboard: ${error.message}` : formatDashboard(data);
  // in_channel = visible to everyone in the channel (not just the person who ran it).
  return new Response(JSON.stringify({ response_type: "in_channel", text }), { status: 200, headers: { "Content-Type": "application/json" } });
});
