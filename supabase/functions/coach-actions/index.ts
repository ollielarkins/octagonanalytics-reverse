// coach-actions — Slack interactivity for the Octagon Coach's buttons (28/10/2026, migration 0129).
//
// Pause for today, Mute this message and Unmute. Nothing here touches RecruitCRM; it only writes
// coach_pause. Public endpoint (Slack cannot send a Supabase JWT), so every request must carry a valid
// Slack signature made with the coach app's signing secret, COACH_SIGNING_SECRET. A person can only
// pause their own coach; in shadow mode the shadow user can press them to test.

import { createClient } from "jsr:@supabase/supabase-js@2";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const BOT = (Deno.env.get("COACH_BOT_TOKEN") ?? "").trim();
const SIGNING = (Deno.env.get("COACH_SIGNING_SECRET") ?? "").trim();

async function hmacHex(key: string, msg: string) {
  const k = await crypto.subtle.importKey("raw", new TextEncoder().encode(key), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", k, new TextEncoder().encode(msg));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
function timingEq(a: string, b: string) {
  if (a.length !== b.length) return false;
  let r = 0; for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}
async function slack(method: string, body: Record<string, unknown>) {
  const r = await fetch(`https://slack.com/api/${method}`, {
    method: "POST", headers: { Authorization: `Bearer ${BOT}`, "Content-Type": "application/json; charset=utf-8" }, body: JSON.stringify(body),
  });
  return await r.json().catch(() => ({ ok: false })) as any;
}
async function emailOf(slackUser: string) {
  const r = await fetch(`https://slack.com/api/users.info?user=${encodeURIComponent(slackUser)}`, { headers: { Authorization: `Bearer ${BOT}` } });
  const j: any = await r.json().catch(() => null);
  return String(j?.user?.profile?.email ?? "").trim().toLowerCase();
}
const today = () => new Intl.DateTimeFormat("en-CA", { timeZone: "Europe/London" }).format(new Date());   // YYYY-MM-DD
const SLOT_NAME: Record<string, string> = { midday: "12:30 message", wrap: "16:45 message", monday: "Monday message", all: "coach" };

async function handle(p: any) {
  const a = p.actions?.[0]; let v: any = {}; try { v = JSON.parse(String(a?.value ?? "{}")); } catch { /* ignore */ }
  const cid = Number(v.c), slot = String(v.slot ?? "");
  const reply = (text: string, extra: any[] = []) => p.channel?.id
    ? slack("chat.postMessage", { channel: p.channel.id, thread_ts: p.message?.ts, text, blocks: [{ type: "section", text: { type: "mrkdwn", text } }, ...extra] })
    : Promise.resolve();
  if (!cid || !SLOT_NAME[slot]) return;
  // Only the person themselves, or the shadow user while testing.
  const email = await emailOf(p.user?.id);
  const [{ data: me }, { data: sh }] = await Promise.all([
    db.from("consultants").select("recruitcrm_id").ilike("email", email || "-").is("deleted_at", null).maybeSingle(),
    db.from("app_settings").select("value").eq("key", "coach_shadow_email").maybeSingle(),
  ]);
  const allowed = (me?.recruitcrm_id && Number(me.recruitcrm_id) === cid) || (email && email === String(sh?.value ?? "").trim().toLowerCase());
  if (!allowed) return reply("That button belongs to someone else's coach, so nothing changed.");
  if (a.action_id === "coach_pause") {
    await db.from("coach_pause").upsert({ consultant_recruitcrm_id: cid, slot: "all", until: today() }, { onConflict: "consultant_recruitcrm_id,slot" });
    return reply("Paused for today. Your coach is back tomorrow.");
  }
  if (a.action_id === "coach_mute") {
    await db.from("coach_pause").upsert({ consultant_recruitcrm_id: cid, slot, until: null }, { onConflict: "consultant_recruitcrm_id,slot" });
    return reply(`Muted the ${SLOT_NAME[slot]}. The others still come.`, [{ type: "actions", elements: [
      { type: "button", action_id: "coach_unmute", text: { type: "plain_text", text: "Unmute" }, value: JSON.stringify({ c: cid, slot }) }] }]);
  }
  if (a.action_id === "coach_unmute") {
    await db.from("coach_pause").delete().eq("consultant_recruitcrm_id", cid).eq("slot", slot);
    return reply(`The ${SLOT_NAME[slot]} is back on.`);
  }
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("method not allowed", { status: 405 });
  if (!SIGNING || !BOT) return new Response("not configured", { status: 503 });
  const raw = await req.text();
  const ts = req.headers.get("x-slack-request-timestamp") ?? "";
  const sig = req.headers.get("x-slack-signature") ?? "";
  if (!ts || Math.abs(Date.now() / 1000 - Number(ts)) > 300) return new Response("stale or missing timestamp", { status: 401 });
  if (!timingEq("v0=" + await hmacHex(SIGNING, `v0:${ts}:${raw}`), sig)) return new Response("bad signature", { status: 401 });
  let p: any = null;
  try { p = JSON.parse(new URLSearchParams(raw).get("payload") ?? "null"); } catch { /* not ours */ }
  if (p?.type === "block_actions" && ["coach_pause", "coach_mute", "coach_unmute"].includes(p.actions?.[0]?.action_id)) {
    // Answer Slack within 3 seconds; do the work after.
    const work = handle(p);
    try { (globalThis as any).EdgeRuntime?.waitUntil(work); } catch { await work; }
  }
  return new Response("", { status: 200 });
});
