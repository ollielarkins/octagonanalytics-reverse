// coach-dm — the Octagon Coach's DMs (28/10/2026, migration 0129).
//
// For each consultant on app_settings.coach_pilot, public.coach_nudges() picks today's nudges for the
// slot (midday 12:30, wrap 16:45, monday 08:45) from their own numbers; this function sends them from
// the Octagon Coach Slack app. Rules only, no AI on the server: each suggestion names the command or
// prompt to use in the person's own Claude.
//
// Shadow mode (app_settings.coach_shadow = 'true'): every DM goes to coach_shadow_email, labelled.
// Needs COACH_BOT_TOKEN (chat:write, im:write, users:read, users:read.email). Driven by pg_cron
// through coach_if_due(), which presents app_settings.cron_bearer, so the function stays locked.

import { createClient } from "jsr:@supabase/supabase-js@2";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const BOT = (Deno.env.get("COACH_BOT_TOKEN") ?? "").trim();

async function slack(method: string, body: Record<string, unknown>) {
  const r = await fetch(`https://slack.com/api/${method}`, {
    method: "POST", headers: { Authorization: `Bearer ${BOT}`, "Content-Type": "application/json; charset=utf-8" }, body: JSON.stringify(body),
  });
  return await r.json().catch(() => ({ ok: false, error: `http_${r.status}` })) as any;
}
async function slackUserByEmail(email: string): Promise<string | null> {
  const r = await fetch(`https://slack.com/api/users.lookupByEmail?email=${encodeURIComponent(email)}`, { headers: { Authorization: `Bearer ${BOT}` } });
  const j: any = await r.json().catch(() => null);
  return j?.ok ? j.user?.id ?? null : null;
}
const esc = (s: unknown) => String(s ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

const SUBTITLE: Record<string, string> = {
  midday: "Logged so far today, against today's share of your plan",
  wrap: "What's left before you finish",
  monday: "Your plan for the week, worked back from your billing target",
};

function blocksFor(n: any, slot: string, cid: number, shadowFor: string | null) {
  const head = (shadowFor ? `Preview for ${shadowFor}: ` : "") + String(n.headline ?? "Your coach");
  const blocks: any[] = [
    { type: "header", text: { type: "plain_text", text: head.slice(0, 150) } },
    { type: "context", elements: [{ type: "mrkdwn", text: SUBTITLE[slot] ?? "" }] },
  ];
  const stats: any[] = n.stats ?? [];
  if (stats.length) blocks.push({ type: "section", fields: stats.slice(0, 10).map((s: any) => ({ type: "mrkdwn",
    text: `*${esc(s.label)}*\n${esc(s.value)}${s.ok === false && !n.early_week ? "  ·  _behind_" : ""}` })) });
  const actions: any[] = n.actions ?? [];
  if (n.quiet && slot === "midday") {
    blocks.push({ type: "section", text: { type: "mrkdwn", text: "On plan and your queue is clear. Good morning's work." } });
  } else if (actions.length) {
    blocks.push({ type: "divider" });
    const title = slot === "midday" ? "*This afternoon*" : slot === "monday" ? "*This week*" : "*Before you go*";
    blocks.push({ type: "section", text: { type: "mrkdwn", text: [title, ...actions.map((a: any, i: number) =>
      `${i + 1}. ${esc(a.text)}${a.prompt ? `  ·  ask Claude: \`${esc(a.prompt)}\`` : ""}`)].join("\n").slice(0, 2900) } });
  }
  if (n.tip?.command) blocks.push({ type: "context", elements: [{ type: "mrkdwn",
    text: `Try today: \`${esc(n.tip.command)}\` ${esc(n.tip.why)}.` }] });
  if (n.early_week && slot === "midday") blocks.push({ type: "context", elements: [{ type: "mrkdwn",
    text: "Early in the week, gaps are normal. Counts are what's logged in RecruitCRM so far." }] });
  blocks.push({ type: "actions", elements: [
    { type: "button", action_id: "coach_pause", text: { type: "plain_text", text: "Pause for today" }, value: JSON.stringify({ c: cid, slot: "all" }) },
    { type: "button", action_id: "coach_mute", text: { type: "plain_text", text: `Mute the ${slot === "midday" ? "12:30" : slot === "wrap" ? "16:45" : "Monday"} message` }, value: JSON.stringify({ c: cid, slot }) },
  ] });
  if (shadowFor) blocks.push({ type: "context", elements: [{ type: "mrkdwn", text: "_Shadow mode: consultants are not getting these yet._" }] });
  return { blocks, text: head };
}

Deno.serve(async (req) => {
  const runAt = new Date().toISOString();
  const record = async (status: string) => {
    await db.from("sync_state").upsert({ entity: "coach", last_run_at: runAt, last_status: status.slice(0, 200) }, { onConflict: "entity" });
  };
  if (!/^xox[bp]-[!-~]+$/.test(BOT)) {
    await record("error:COACH_BOT_TOKEN missing or malformed");
    return Response.json({ sent: 0, reason: "COACH_BOT_TOKEN missing or malformed" });
  }
  let body: any = {}; try { body = await req.json(); } catch { /* empty */ }
  const slot = String(body.slot ?? "");
  if (!["midday", "wrap", "monday"].includes(slot)) return Response.json({ sent: 0, reason: "slot must be midday, wrap or monday" }, { status: 400 });

  const { data: settings } = await db.from("app_settings").select("key,value").in("key", ["coach_pilot", "coach_shadow", "coach_shadow_email"]);
  const s = new Map((settings ?? []).map((r: any) => [r.key, String(r.value ?? "").trim()]));
  const ids = (s.get("coach_pilot") ?? "").split(",").map((x) => Number(x.trim())).filter(Boolean);
  const shadow = s.get("coach_shadow") !== "false";
  const shadowUser = shadow ? await slackUserByEmail(s.get("coach_shadow_email") ?? "") : null;
  if (shadow && !shadowUser) { await record("error:shadow user not found in Slack"); return Response.json({ sent: 0, reason: "shadow user not found" }); }

  const { data: people } = await db.from("consultants").select("recruitcrm_id,name,email").in("recruitcrm_id", ids).is("deleted_at", null);
  const results: any[] = [];
  for (const c of people ?? []) {
    try {
      const { data: n, error } = await db.rpc("coach_nudges", { p_consultant: c.recruitcrm_id, p_slot: slot });
      if (error) { results.push({ consultant: c.name, sent: false, reason: error.message }); continue; }
      if (n?.skip) { results.push({ consultant: c.name, sent: false, reason: n.reason }); continue; }
      // Nothing to say at the wrap-up: send nothing rather than an empty nudge.
      if (n?.quiet && slot === "wrap") { results.push({ consultant: c.name, sent: false, reason: "nothing to say" }); continue; }
      const target = shadow ? shadowUser : (c.email ? await slackUserByEmail(c.email) : null);
      if (!target) { results.push({ consultant: c.name, sent: false, reason: "no Slack user for their email" }); continue; }
      const im = await slack("conversations.open", { users: target });
      if (!im.ok) { results.push({ consultant: c.name, sent: false, reason: `conversations.open: ${im.error}` }); continue; }
      const msg = blocksFor(n, slot, c.recruitcrm_id, shadow ? c.name : null);
      const post = await slack("chat.postMessage", { channel: im.channel.id, text: msg.text, blocks: msg.blocks, unfurl_links: false });
      if (post.ok) await db.from("coach_log").insert({ consultant_recruitcrm_id: c.recruitcrm_id, slot, shadow, suggested: n.suggested ?? [] });
      results.push({ consultant: c.name, sent: !!post.ok, actions: (n.actions ?? []).length, reason: post.ok ? undefined : `chat.postMessage: ${post.error}` });
    } catch (e) {
      results.push({ consultant: c.name, sent: false, reason: String(e).slice(0, 160) });
    }
  }
  const sent = results.filter((r) => r.sent).length;
  const failed = results.filter((r) => !r.sent && !["nothing to say", "paused"].includes(r.reason));
  await record(failed.length ? `partial:${slot} ${sent} sent, ${failed.length} failed` : `ok:${slot} ${sent} sent${shadow ? " (shadow)" : ""}`);
  return Response.json({ slot, shadow, sent, results });
});
