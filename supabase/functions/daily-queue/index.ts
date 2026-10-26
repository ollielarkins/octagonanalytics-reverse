// daily-queue — the 08:30 daily action queue DM (priority 4, Bhav 20/10/2026; migration 0115).
//
// For each pilot consultant (app_settings.action_queue_pilot), public.action_queue() ranks today's
// calls; this function sends them as a Slack DM. Drafting stays in the consultant's own Claude
// ("prep my queue"), per the 13/10/2026 rule of no server-side AI, so nothing here writes content.
//
// Shadow mode (app_settings.action_queue_shadow = 'true'): every DM goes to the shadow address,
// labelled with whose it is, so the ranking can be checked before consultants see it.
//
// Needs SLACK_BOT_TOKEN (scopes chat:write, im:write, users:read, users:read.email). Without it the
// run records the reason and sends nothing. Driven by pg_cron through action_queue_if_due(), which
// presents app_settings.cron_bearer, so the function stays locked (verify_jwt).

import { createClient } from "jsr:@supabase/supabase-js@2";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const BOT = (Deno.env.get("SLACK_BOT_TOKEN") ?? "").trim();

async function slack(method: string, body: Record<string, unknown>) {
  const r = await fetch(`https://slack.com/api/${method}`, {
    method: "POST",
    headers: { Authorization: `Bearer ${BOT}`, "Content-Type": "application/json; charset=utf-8" },
    body: JSON.stringify(body),
  });
  const j = await r.json().catch(() => ({ ok: false, error: `http_${r.status}` }));
  return j as any;
}
// users.lookupByEmail is a GET-style method; form-encode it.
async function slackUserByEmail(email: string): Promise<string | null> {
  const r = await fetch(`https://slack.com/api/users.lookupByEmail?email=${encodeURIComponent(email)}`, { headers: { Authorization: `Bearer ${BOT}` } });
  const j: any = await r.json().catch(() => null);
  return j?.ok ? j.user?.id ?? null : null;
}
const esc = (s: unknown) => String(s ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

const NOT_CALLS: Record<string, string> = { plan: ":dart:", cleanup: ":broom:", meetings: ":spiral_calendar_pad:", client_visits: ":handshake:" };

function blocksFor(q: any, shadowFor: string | null) {
  const first = String(q.consultant ?? "").split(" ")[0];
  // Closing lines that are not calls (0116, 0118) stay out of the numbering and the counts.
  const all: any[] = q.items ?? [];
  const items = all.filter((x) => !NOT_CALLS[x.kind]);
  const closing = all.filter((x) => NOT_CALLS[x.kind]);
  const head = shadowFor
    ? `Preview for ${shadowFor}: ${items.length} of ${q.total} calls`
    : `Your calls today, ${first}: ${items.length} of ${q.total}`;
  const blocks: any[] = [{ type: "header", text: { type: "plain_text", text: head.slice(0, 150) } }];
  if (!items.length) blocks.push({ type: "section", text: { type: "mrkdwn", text: "_Nothing urgent today._" } });
  // 0118: one section per call with a Done button. slack-actions previews what Done writes to
  // RecruitCRM and only writes it when the consultant confirms.
  items.forEach((x, i) => {
    const what = [x.who, x.job, x.client].filter(Boolean).map(esc).join(" · ");
    const block: any = { type: "section", text: { type: "mrkdwn", text: `*${i + 1}. ${esc(x.action)}*${what ? `\n${what}` : ""}`.slice(0, 2900) } };
    // The form must open within Slack's 3 seconds, so the button carries what it shows; slack-actions
    // re-checks the item against the consultant's own queue before writing anything.
    if (x.item_key) block.accessory = { type: "button", action_id: "queue_done", text: { type: "plain_text", text: "Done" },
      value: JSON.stringify({ k: x.item_key, kind: x.kind, a: x.action, who: x.who, job: x.job, client: x.client, cs: x.candidate_slug }).slice(0, 1900) };
    blocks.push(block);
  });
  for (const x of closing) {
    blocks.push({ type: "section", text: { type: "mrkdwn", text: `${NOT_CALLS[x.kind]} *${esc(x.action)}*${x.who ? `\n${esc(x.who)}` : ""}`.slice(0, 2900) } });
  }
  const more = Number(q.total) - items.length;
  blocks.push({ type: "context", elements: [{ type: "mrkdwn", text:
    (more > 0 ? `${more} more not shown, lowest priority first. ` : "") +
    "Want the drafts? Ask Claude *prep my queue*: prep notes, chase and booking emails, Boolean searches and InMails, all as drafts for you to check." }] });
  if (shadowFor) blocks.push({ type: "context", elements: [{ type: "mrkdwn", text: "_Shadow mode: consultants are not getting these yet._" }] });
  return { blocks, text: head };
}

Deno.serve(async () => {
  const runAt = new Date().toISOString();
  const record = async (status: string) => {
    await db.from("sync_state").upsert({ entity: "action_queue", last_run_at: runAt, last_status: status.slice(0, 200) }, { onConflict: "entity" });
  };
  if (!BOT) {
    await record("error:no SLACK_BOT_TOKEN");
    return Response.json({ sent: 0, reason: "SLACK_BOT_TOKEN is not set" });
  }
  // 26/10/2026: the first run died inside fetch ("not a valid ByteString") before recording anything,
  // because the stored token held a character that cannot go in a header. Check the shape first and
  // say so, without ever echoing the token.
  if (!/^xox[bp]-[!-~]+$/.test(BOT)) {
    await record("error:SLACK_BOT_TOKEN is malformed (expected xoxb-..., plain ASCII, no quotes or ellipsis)");
    return Response.json({ sent: 0, reason: "SLACK_BOT_TOKEN is malformed" });
  }
  const { data: settings } = await db.from("app_settings").select("key,value")
    .in("key", ["action_queue_pilot", "action_queue_shadow", "action_queue_shadow_email"]);
  const s = new Map((settings ?? []).map((r: any) => [r.key, String(r.value ?? "").trim()]));
  const ids = (s.get("action_queue_pilot") ?? "").split(",").map((x) => Number(x.trim())).filter(Boolean);
  const shadow = s.get("action_queue_shadow") !== "false";
  const shadowEmail = s.get("action_queue_shadow_email") ?? "";
  if (!ids.length) { await record("ok:no pilot consultants"); return Response.json({ sent: 0, reason: "no pilot consultants" }); }

  let shadowUser: string | null = null;
  try { shadowUser = shadow && shadowEmail ? await slackUserByEmail(shadowEmail) : null; }
  catch (e) { await record(`error:Slack lookup failed: ${String(e).slice(0, 120)}`); return Response.json({ sent: 0, reason: "Slack lookup failed" }); }
  if (shadow && !shadowUser) { await record("error:shadow user not found in Slack"); return Response.json({ sent: 0, reason: "shadow user not found" }); }

  const { data: people } = await db.from("consultants").select("recruitcrm_id,name,email").in("recruitcrm_id", ids).is("deleted_at", null);
  const results: any[] = [];
  for (const c of people ?? []) {
    try {
      const { data: q, error } = await db.rpc("action_queue", { p_consultant: c.recruitcrm_id });
      if (error) { results.push({ consultant: c.name, sent: false, reason: error.message }); continue; }
      if (!(q?.items ?? []).length) { results.push({ consultant: c.name, sent: false, reason: "nothing to send" }); continue; }
      const target = shadow ? shadowUser : (c.email ? await slackUserByEmail(c.email) : null);
      if (!target) { results.push({ consultant: c.name, sent: false, reason: "no Slack user for their email" }); continue; }
      const im = await slack("conversations.open", { users: target });
      if (!im.ok) { results.push({ consultant: c.name, sent: false, reason: `conversations.open: ${im.error}` }); continue; }
      const msg = blocksFor(q, shadow ? c.name : null);
      const post = await slack("chat.postMessage", { channel: im.channel.id, text: msg.text, blocks: msg.blocks, unfurl_links: false });
      results.push({ consultant: c.name, sent: !!post.ok, items: q.items.length, total: q.total, reason: post.ok ? undefined : `chat.postMessage: ${post.error}` });
    } catch (e) {
      results.push({ consultant: c.name, sent: false, reason: String(e).slice(0, 160) });
    }
  }
  const sent = results.filter((r) => r.sent).length;
  const failed = results.filter((r) => !r.sent && r.reason !== "nothing to send");
  await record(failed.length ? `partial:${sent} sent, ${failed.length} failed` : `ok:${sent} sent${shadow ? " (shadow)" : ""}`);
  return Response.json({ shadow, sent, results });
});
