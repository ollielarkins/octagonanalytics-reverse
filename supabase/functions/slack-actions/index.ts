// slack-actions — Slack interactivity for the 08:30 action queue (queue phase 2, migration 0118).
//
// The Done button on a call in the daily DM opens a small form that says exactly what will be
// written to RecruitCRM (a note on the candidate) with an optional outcome; it is written only when
// the consultant presses Confirm. That keeps the platform rule: every write previews first and
// applies only on explicit confirmation. Calls with nothing to record (a cold job, BD) are just
// marked done. Done items go into action_queue_done so they do not come back the next morning.
//
// Public endpoint (Slack cannot send a Supabase JWT), so every request must carry a valid Slack
// signature made with the Team Briefs app's signing secret, SLACK_BRIEFS_SIGNING_SECRET. The Slack
// user is matched to a consultant by work email, and the item must be on that consultant's own queue.

import { createClient } from "jsr:@supabase/supabase-js@2";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const BOT = (Deno.env.get("SLACK_BOT_TOKEN") ?? "").trim();
const SIGNING = (Deno.env.get("SLACK_BRIEFS_SIGNING_SECRET") ?? "").trim();
const CRM = (Deno.env.get("RECRUIT_CRM_API_TOKEN") ?? Deno.env.get("RECRUITCRM_API_TOKEN") ?? "").trim();

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
async function consultantFor(slackUser: string) {
  const r = await fetch(`https://slack.com/api/users.info?user=${encodeURIComponent(slackUser)}`, { headers: { Authorization: `Bearer ${BOT}` } });
  const j: any = await r.json().catch(() => null);
  const email = String(j?.user?.profile?.email ?? "").trim().toLowerCase();
  if (!email) return null;
  const { data } = await db.from("consultants").select("recruitcrm_id,name,email").ilike("email", email).is("deleted_at", null).maybeSingle();
  return data;
}
async function findItem(consultantId: number, key: string) {
  const { data } = await db.rpc("action_queue", { p_consultant: consultantId });
  return ((data?.items ?? []) as any[]).find((x) => x.item_key === key) ?? null;
}

const today = () => new Intl.DateTimeFormat("en-GB", { timeZone: "Europe/London", day: "2-digit", month: "2-digit", year: "numeric" }).format(new Date());
const NOTE: Record<string, string> = {
  offer: "Offer follow-up: called the candidate and the client",
  prep: "Interview prep call done",
  feedback: "Interview feedback chased with the client",
  unbooked: "Booking call for the interview request",
  cv_chase: "Chased the client on the CV",
  rejected: "Candidate updated after the client's rejection",
};
// Days an item stays off the queue once done. prep and feedback keys belong to one meeting.
const HIDE: Record<string, number> = { offer: 2, unbooked: 2, cv_chase: 5, cold_job: 7, bd: 7, prep: 30, feedback: 30, new_job: 30, rejected: 30 };
function noteText(item: any, outcome: string) {
  const parts = [`${NOTE[item.kind]} (${today()})${item.job ? `. Job: ${item.job}` : ""}.`];
  if (outcome) parts.push(`Outcome: ${outcome}`);
  parts.push("(Logged from the Octagon daily queue.)");
  return parts.join(" ");
}
const esc = (s: unknown) => String(s ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

// 0125: a confirmed Done turns that call's button into "Completed". chat.update replaces the whole
// message, so the message's latest blocks are kept in slack_queue_messages (the bot cannot read its
// own DMs back) and each update builds on them, keeping earlier Completed buttons.
const keyOf = (el: any) => { try { return String(JSON.parse(String(el?.value ?? "{}")).k ?? ""); } catch { return ""; } };
async function saveBlocks(ch: string, ts: string, blocks: any[]) {
  await db.from("slack_queue_messages").upsert({ channel_id: ch, message_ts: ts, blocks, updated_at: new Date().toISOString() },
    { onConflict: "channel_id,message_ts" });
}
async function markCompleted(ch: string | null, ts: string | null, key: string) {
  if (!ch || !ts || !key) return;
  const { data } = await db.from("slack_queue_messages").select("blocks").eq("channel_id", ch).eq("message_ts", ts).maybeSingle();
  const blocks: any[] = data?.blocks ?? [];
  let hit = false;
  for (const b of blocks) {
    if (b?.accessory?.action_id === "queue_done" && keyOf(b.accessory) === key) {
      b.accessory = { type: "button", action_id: "queue_completed", style: "primary", text: { type: "plain_text", text: "Completed" }, value: b.accessory.value };
      hit = true;
    }
  }
  if (!hit) return;
  const head = blocks.find((b) => b?.type === "header")?.text?.text ?? "Your calls today";
  const up = await slack("chat.update", { channel: ch, ts, text: head, blocks });
  if (up.ok) await saveBlocks(ch, ts, blocks);
}

// Opens at once from what the button carries (Slack's 3-second limit); confirm() re-checks it.
async function openForm(p: any) {
  let v: any = {}; try { v = JSON.parse(String(p.actions?.[0]?.value ?? "{}")); } catch { /* old button */ }
  const key = String(v.k ?? "");
  if (!key) return;
  const item = { kind: v.kind, action: v.a, who: v.who, job: v.job, client: v.client, candidate_slug: v.cs };
  const writes = !!(item.candidate_slug && NOTE[item.kind]);
  const blocks: any[] = [
    { type: "section", text: { type: "mrkdwn", text: `*${esc(item.action)}*\n${[item.who, item.job, item.client].filter(Boolean).map(esc).join(" · ")}` } },
    { type: "section", text: { type: "mrkdwn", text: writes
      ? `On Confirm, this note is saved on *${esc(item.who)}* in RecruitCRM, as you:\n>${esc(noteText(item, "…"))}`
      : "Nothing is written to RecruitCRM. This just takes it off your list." } },
  ];
  if (writes) blocks.push({ type: "input", block_id: "outcome", optional: true, label: { type: "plain_text", text: "Outcome (optional)" },
    element: { type: "plain_text_input", action_id: "text", multiline: true, max_length: 1000 } });
  await slack("views.open", { trigger_id: p.trigger_id, view: {
    type: "modal", callback_id: "queue_done", title: { type: "plain_text", text: "Mark done" },
    submit: { type: "plain_text", text: "Confirm" }, close: { type: "plain_text", text: "Cancel" },
    private_metadata: JSON.stringify({ k: key, ch: p.channel?.id ?? null, ts: p.message?.ts ?? null }), blocks } });
  // After the form is open (the trigger has a 3-second life): keep the message as it stands now.
  if (p.channel?.id && p.message?.ts && Array.isArray(p.message?.blocks)) {
    await saveBlocks(p.channel.id, p.message.ts, p.message.blocks).catch(() => {});
  }
}

async function confirm(p: any) {
  let meta: any = {}; try { meta = JSON.parse(p.view?.private_metadata ?? "{}"); } catch { /* keep empty */ }
  const outcome = String(p.view?.state?.values?.outcome?.text?.value ?? "").trim();
  const reply = (text: string) => meta.ch ? slack("chat.postMessage", { channel: meta.ch, thread_ts: meta.ts ?? undefined, text }) : Promise.resolve();
  const who = await consultantFor(p.user?.id);
  if (!who) return reply("I couldn't match your Slack account to a consultant, so nothing was changed.");
  const item = await findItem(who.recruitcrm_id, String(meta.k ?? ""));
  if (!item) {
    const { data: done } = await db.from("action_queue_done").select("item_key")
      .eq("consultant_recruitcrm_id", who.recruitcrm_id).eq("item_key", String(meta.k ?? "")).maybeSingle();
    if (done) await markCompleted(meta.ch, meta.ts, String(meta.k));
    return reply(done ? "That one is already done, so nothing was changed." : "That one is no longer on your list, so nothing was changed.");
  }
  let noteOk = false, noteErr = "";
  if (item.candidate_slug && NOTE[item.kind]) {
    const r = await fetch("https://api.recruitcrm.io/v1/notes", {
      method: "POST", headers: { Authorization: `Bearer ${CRM}`, Accept: "application/json", "Content-Type": "application/json" },
      body: JSON.stringify({ description: noteText(item, outcome), related_to: item.candidate_slug, related_to_type: "candidate", updated_by: who.recruitcrm_id }),
    });
    noteOk = r.ok; if (!r.ok) noteErr = `RecruitCRM said ${r.status}`;
  }
  if (item.candidate_slug && NOTE[item.kind] && !noteOk) return reply(`I couldn't save the note on ${item.who} (${noteErr}), so it stays on your list. Nothing was changed.`);
  const hide = new Date(Date.now() + (HIDE[item.kind] ?? 3) * 86400_000).toISOString().slice(0, 10);
  await db.from("action_queue_done").upsert({ consultant_recruitcrm_id: who.recruitcrm_id, item_key: item.item_key, kind: item.kind, hide_until: hide, note_written: noteOk },
    { onConflict: "consultant_recruitcrm_id,item_key" });
  await db.from("audit_log").insert({ actor: String(who.recruitcrm_id), action: "queue_done", entity: item.candidate_slug ? "candidate" : "queue_item",
    entity_id: item.candidate_slug ?? item.item_key, before: null, after: { kind: item.kind, note_written: noteOk }, via: "slack" }).then(() => {}, () => {});
  await markCompleted(meta.ch, meta.ts, item.item_key).catch(() => {});
  await reply(noteOk ? `:white_check_mark: Done. Note saved on ${item.who} in RecruitCRM.` : ":white_check_mark: Done. Off your list.");
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
  if (!p) return new Response("", { status: 200 });
  // Slack wants an answer within 3 seconds: views.open uses the trigger at once, the note is written
  // after the modal has closed.
  if (p.type === "block_actions" && p.actions?.[0]?.action_id === "queue_done") {
    await openForm(p);
    return new Response("", { status: 200 });
  }
  // A Completed button does nothing; acknowledge so Slack doesn't show an error.
  if (p.type === "block_actions" && p.actions?.[0]?.action_id === "queue_completed") return new Response("", { status: 200 });
  if (p.type === "view_submission" && p.view?.callback_id === "queue_done") {
    const work = confirm(p);
    try { (globalThis as any).EdgeRuntime?.waitUntil(work); } catch { await work; }
    return new Response("", { status: 200 });
  }
  return new Response("", { status: 200 });
});
