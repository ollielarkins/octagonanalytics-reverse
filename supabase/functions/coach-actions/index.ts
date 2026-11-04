// coach-actions — Slack interactivity for the Octagon Coach's buttons (28/10/2026, migration 0129).
//
// Pause for today, Mute this message and Unmute write coach_pause. Public endpoint (Slack cannot send
// a Supabase JWT), so every request must carry a valid Slack signature made with the coach app's
// signing secret, COACH_SIGNING_SECRET. A person can only press their own coach's buttons; in shadow
// mode the shadow user can press them to test.
//
// 0147 (04/11/2026): Done and Snooze to tomorrow on each suggestion (coach_feedback + coach_snooze),
// and "Tag these as shown" on the 16:45 call list. That one writes to RecruitCRM: the message listed
// every call and its category (the preview), the press is the recruiter's confirmation, and only the
// calls in that message are touched, each checked to be theirs and still untagged, read back, and
// stopped at the first problem. A message sent in shadow mode never writes: it says what it would do.

import { createClient } from "jsr:@supabase/supabase-js@2";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const BOT = (Deno.env.get("COACH_BOT_TOKEN") ?? "").trim();
const CRM = (Deno.env.get("RECRUIT_CRM_API_TOKEN") ?? Deno.env.get("RECRUITCRM_API_TOKEN") ?? "").trim();
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
async function crm(method: string, path: string, body?: any) {
  const r = await fetch(`https://api.recruitcrm.io/v1${path}`, {
    method, headers: { Authorization: `Bearer ${CRM}`, Accept: "application/json", "Content-Type": "application/json" },
    body: body ? JSON.stringify(body) : undefined,
  });
  const j: any = await r.json().catch(() => null);
  return { ok: r.ok, status: r.status, data: j?.data ?? j };
}
const today = () => new Intl.DateTimeFormat("en-CA", { timeZone: "Europe/London" }).format(new Date());   // YYYY-MM-DD
const SLOT_NAME: Record<string, string> = { midday: "12:30 message", wrap: "16:45 message", monday: "Monday message", all: "coach" };

// Who pressed, and may they? The person the message was for, or the shadow user while testing.
async function allowedFor(p: any, cid: number) {
  const email = await emailOf(p.user?.id);
  const [{ data: me }, { data: sh }] = await Promise.all([
    db.from("consultants").select("recruitcrm_id").ilike("email", email || "-").is("deleted_at", null).maybeSingle(),
    db.from("app_settings").select("value").eq("key", "coach_shadow_email").maybeSingle(),
  ]);
  return !!((me?.recruitcrm_id && Number(me.recruitcrm_id) === cid) || (email && email === String(sh?.value ?? "").trim().toLowerCase()));
}

// Rewrite one suggestion in the original message: drop its buttons and say what happened.
async function markItem(p: any, idx: number, label: string) {
  const blocks: any[] = Array.isArray(p.message?.blocks) ? p.message.blocks : [];
  if (!p.channel?.id || !p.message?.ts || !blocks.length) return;
  const out = blocks.filter((b: any) => b.block_id !== `t${idx}`).map((b: any) => {
    if (b.block_id !== `a${idx}`) return b;
    const { accessory: _drop, ...rest } = b;
    return { ...rest, text: { ...b.text, text: `${String(b.text?.text ?? "")}\n_${label}_`.slice(0, 2990) } };
  });
  await slack("chat.update", { channel: p.channel.id, ts: p.message.ts, blocks: out, text: p.message.text ?? "Your coach" });
}

async function handleItem(p: any) {
  const a = p.actions?.[0];
  const raw = String(a?.selected_option?.value ?? a?.value ?? "");
  const [op, logStr, idxStr] = raw.split("|");
  const logId = Number(logStr), idx = Number(idxStr);
  const reply = (text: string) => p.channel?.id
    ? slack("chat.postMessage", { channel: p.channel.id, thread_ts: p.message?.ts, text })
    : Promise.resolve();
  if (!["d", "s", "t"].includes(op) || !logId || !Number.isInteger(idx)) return;
  const { data: log } = await db.from("coach_log").select("id,consultant_recruitcrm_id,shadow,actions").eq("id", logId).maybeSingle();
  const act = Array.isArray(log?.actions) ? log.actions[idx] : null;
  if (!log || !act) return reply("That message is too old to act on, so nothing changed.");
  const cid = Number(log.consultant_recruitcrm_id);
  if (!(await allowedFor(p, cid))) return reply("That button belongs to someone else's coach, so nothing changed.");

  if (op === "d" || op === "s") {
    // Done: not suggested again for 3 days. Snooze: back tomorrow.
    const until = op === "d" ? new Date(Date.parse(today() + "T12:00:00Z") + 2 * 86400_000).toISOString().slice(0, 10) : today();
    await db.from("coach_snooze").upsert({ consultant_recruitcrm_id: cid, action_key: String(act.key ?? ""), until }, { onConflict: "consultant_recruitcrm_id,action_key" });
    await db.from("coach_feedback").insert({ coach_log_id: logId, action_idx: idx, consultant_recruitcrm_id: cid, action_key: act.key ?? null, response: op === "d" ? "done" : "snooze" });
    return markItem(p, idx, op === "d" ? "Done" : "Snoozed to tomorrow");
  }

  // Tag the calls listed in this message, exactly as shown.
  if (act.kind !== "tag_calls" || !Array.isArray(act.calls) || !act.calls.length) return;
  const calls = act.calls.slice(0, 25);
  if (log.shadow) {
    return reply(`Shadow mode: this would tag ${calls.length} ${calls.length === 1 ? "call" : "calls"} in RecruitCRM for the recruiter. Nothing was changed.`);
  }
  if (!CRM) return reply("The coach can't reach RecruitCRM right now, so nothing was changed. Ask Claude: `/tagcalls`");
  const ty = await crm("GET", "/custom-call-types");
  const list: any[] = Array.isArray(ty.data) ? ty.data : (ty.data?.records ?? []);
  const typeId = new Map(list.map((t: any) => [String(t.label ?? t.name ?? "").trim(), Number(t.id)]));
  // Only this person's calls that are still untagged; anything tagged since the message is left alone.
  const { data: rows } = await db.from("call_activity").select("recruitcrm_id,custom_call_type,consultant_recruitcrm_id")
    .in("recruitcrm_id", calls.map((c: any) => Number(c.id)));
  const byId = new Map((rows ?? []).map((r: any) => [Number(r.recruitcrm_id), r]));
  let done = 0, skipped = 0; let problem = "";
  for (const c of calls) {
    const row: any = byId.get(Number(c.id));
    const id = typeId.get(String(c.type));
    if (!row || Number(row.consultant_recruitcrm_id) !== cid || row.custom_call_type) { skipped++; continue; }
    if (!id) { problem = `RecruitCRM has no category called ${c.type}`; break; }
    const cur = await crm("GET", `/call-logs/${c.id}`);
    if (!cur.ok || String(cur.data?.created_by ?? "") !== String(cid)) { problem = `couldn't confirm the ${c.at} call is yours`; break; }
    const w = await crm("POST", `/call-logs/${c.id}`, { custom_call_type_id: id, updated_by: cid });
    if (!w.ok) { problem = `RecruitCRM said ${w.status} on the ${c.at} call`; break; }
    const back = await crm("GET", `/call-logs/${c.id}`);
    const b = back.data ?? {};
    // Only the category may change: if anything else moved (the Devyce summary above all), stop.
    const ignore = /^(custom_call_type|custom_call_type_id|updated_on|updated_by|modified|modified_on|last_modified)$/;
    const norm = (v: any) => (v == null || v === "" ? "" : typeof v === "object" ? JSON.stringify(v) : String(v));
    const drift = Object.keys(cur.data ?? {}).filter((k) => !ignore.test(k) && norm(b?.[k]) !== norm(cur.data?.[k]));
    const typed = (b?.custom_call_type?.label ?? null) === c.type || Number(b?.custom_call_type?.id ?? b?.custom_call_type_id ?? NaN) === id;
    await db.from("audit_log").insert({ actor: String(cid), action: "set_call_type", entity: "call_log", entity_id: String(c.id),
      before: { custom_call_type: null }, after: { custom_call_type: c.type, drift }, via: "coach" }).then(() => {}, () => {});
    if (!typed || drift.length) { problem = typed ? `other fields changed on the ${c.at} call, so I stopped` : `the category didn't stick on the ${c.at} call`; break; }
    await db.from("call_activity").update({ custom_call_type: c.type }).eq("recruitcrm_id", Number(c.id));
    done++;
  }
  await db.from("coach_feedback").insert({ coach_log_id: logId, action_idx: idx, consultant_recruitcrm_id: cid, action_key: act.key ?? null,
    response: "tagged", detail: { tagged: done, skipped, problem: problem || null } });
  const msg = `Tagged ${done} of ${calls.length}${skipped ? ` (${skipped} already tagged or not yours, left alone)` : ""}.`
    + (problem ? ` Stopped: ${problem}. Check it in RecruitCRM, or ask Claude: /tagcalls` : " They count now.");
  await markItem(p, idx, msg);
}

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
  const aid = p?.actions?.[0]?.action_id;
  if (p?.type === "block_actions" && ["coach_pause", "coach_mute", "coach_unmute", "coach_item", "coach_tag"].includes(aid)) {
    // Answer Slack within 3 seconds; do the work after.
    const work = ["coach_item", "coach_tag"].includes(aid) ? handleItem(p) : handle(p);
    try { (globalThis as any).EdgeRuntime?.waitUntil(work); } catch { await work; }
  }
  return new Response("", { status: 200 });
});
