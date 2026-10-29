// inbox-sync — checks every connected Outlook inbox for new mail and records its envelope.
//
// Driven by pg_cron every 5 minutes (0085, job inbox-poll). For each enabled row in inbox_mailboxes
// it runs a Graph delta query on the Inbox folder, so each run fetches only what changed since the
// last one. The first run for a mailbox looks back 24 hours, not at the whole inbox.
//
// Stored: sender, subject, time, thread, read state and a rule-based category. NOT stored: bodies.
// The ~255-char preview Graph returns is used to classify and then dropped. Reading a full message
// happens live in octagon-mcp, only when its owner asks.
//
// Categories are decided by rules, not a model, so the decision is predictable and explainable:
//   never     — negotiations, offers, salary/fees, complaints, legal. Shown, but flagged: a reply
//               to one of these is the recruiter's own call, never a suggested draft.
//   automated — out-of-office, bounces, no-reply senders. Counted, not surfaced.
//   routine   — scheduling, acknowledgements, confirmations, admin.
//   other     — everything else.
// "never" is checked first, so an email that is both ("thanks — about the offer") is never-touch.
import { createClient } from "jsr:@supabase/supabase-js@2";
import { graph, graphConfigured, mbx } from "../_shared/graph.ts";
import { forbidden, trustedCaller } from "../_shared/caller.ts";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const SELECT = "subject,from,receivedDateTime,importance,isRead,conversationId,inferenceClassification,bodyPreview";
const MAX_PAGES = 10;            // per mailbox per run; a backlog continues next run from the saved link
const LOOKBACK_HOURS = 24;       // first run only

const NEVER: [RegExp, string][] = [
  // Deliberately broad: a false "never" costs a recruiter one manual reply, a false "routine" on an
  // offer email costs far more.
  [/\b(counter[- ]?offers?|offers?|offered)\b/i, "offer"],
  [/\b(salary|salaries|package|compensation|remuneration|day rate|hourly rate|rates?\b|pay rise|bonus)/i, "pay"],
  [/\b(negotiat\w*|notice period|resign\w*)/i, "negotiation"],
  [/\b(fee|fees|invoice|payment terms|terms of business|rebate)\b/i, "fees"],
  [/\b(complain\w*|unhappy|disappointed|dissatisf\w*|escalat\w*|unacceptable)/i, "complaint"],
  [/\b(legal|solicitor|lawyer|contract|gdpr|subject access|data protection)\b/i, "legal"],
  [/£\s?\d/, "money"],
];
const AUTOMATED_SENDER = /(no-?reply|do-?not-?reply|notifications?|mailer-daemon|postmaster|bounce)/i;
const AUTOMATED_SUBJECT = /^(automatic reply|auto(matic)?[- ]?reply|out of (the )?office|undeliverable|delivery (status|has failed)|mail delivery)/i;
const ROUTINE: [RegExp, string][] = [
  [/^(accepted|declined|tentative|updated invitation|invitation|canceled|cancelled):/i, "calendar"],
  [/\b(meeting|call|catch[- ]?up|availability|available|reschedul\w*|calendar|invite|slot|diary|time to talk)\b/i, "scheduling"],
  [/\b(thanks|thank you|received|acknowledg\w*|noted|confirm\w*)\b/i, "acknowledgement"],
  [/\b(reminder|timesheet|form|document|details|update|following up|follow[- ]up)\b/i, "admin"],
];

function classify(m: any): { category: string; reason: string } {
  const from = String(m.from?.emailAddress?.address ?? "");
  const subject = String(m.subject ?? "");
  const text = `${subject} ${m.bodyPreview ?? ""}`;
  if (AUTOMATED_SENDER.test(from) || AUTOMATED_SUBJECT.test(subject)) return { category: "automated", reason: "automated sender or subject" };
  for (const [re, why] of NEVER) if (re.test(text)) return { category: "never", reason: why };
  for (const [re, why] of ROUTINE) if (re.test(text)) return { category: "routine", reason: why };
  return { category: "other", reason: "no rule matched" };
}

function firstUrl(mailbox: string) {
  const since = new Date(Date.now() - LOOKBACK_HOURS * 3600_000).toISOString();
  return `${mbx(mailbox)}/mailFolders/inbox/messages/delta?$select=${SELECT}&$filter=receivedDateTime+ge+${since}`;
}

async function syncMailbox(row: any) {
  const owner = row.consultant_recruitcrm_id, mailbox = String(row.mailbox).toLowerCase();
  let url: string = row.delta_link || firstUrl(mailbox);
  let cursor: string | null = null, added = 0, removed = 0, pages = 0, reset = false;
  const cutoff = Date.now() - 30 * 86400_000;

  while (url && pages < MAX_PAGES) {
    const r = await graph("GET", url, undefined, { Prefer: "odata.maxpagesize=50" });
    // An expired or invalid delta token: start again from the lookback window rather than failing forever.
    if (!r.ok && (r.status === 410 || /syncStateNotFound|resyncRequired/i.test(r.text)) && !reset) {
      reset = true; url = firstUrl(mailbox); continue;
    }
    if (!r.ok) throw new Error(`graph ${r.status} ${String(r.json?.error?.code ?? r.text).slice(0, 120)}`);
    pages++;
    const rows: any[] = [], gone: string[] = [];
    for (const m of r.json?.value ?? []) {
      if (m["@removed"]) { gone.push(m.id); continue; }
      // Read-state changes arrive for messages outside the filter and without a received time; only
      // rows we already hold are worth updating, and those carry received_at already.
      if (!m.receivedDateTime) { await db.from("inbox_messages").update({ is_read: m.isRead ?? null }).eq("id", m.id); continue; }
      if (Date.parse(m.receivedDateTime) < cutoff) continue;
      const from = String(m.from?.emailAddress?.address ?? "").toLowerCase();
      if (from === mailbox) continue;                       // their own mail in their inbox
      const { category, reason } = classify(m);
      rows.push({ id: m.id, consultant_recruitcrm_id: owner, conversation_id: m.conversationId ?? null,
        from_name: m.from?.emailAddress?.name ?? null, from_address: from || null, subject: m.subject ?? null,
        received_at: m.receivedDateTime, importance: m.importance ?? null, is_read: m.isRead ?? null,
        focused: m.inferenceClassification ? m.inferenceClassification === "focused" : null, category, reason });
    }
    if (rows.length) { const { error } = await db.from("inbox_messages").upsert(rows, { onConflict: "id" }); if (error) throw new Error(error.message); added += rows.length; }
    if (gone.length) { await db.from("inbox_messages").delete().in("id", gone); removed += gone.length; }
    if (r.json?.["@odata.deltaLink"]) { cursor = r.json["@odata.deltaLink"]; url = ""; }
    else { cursor = r.json?.["@odata.nextLink"] ?? null; url = cursor ?? ""; }
  }
  const status = `ok +${added} -${removed} pages=${pages}${reset ? " reset" : ""}${url ? " more" : ""}`;
  await db.from("inbox_mailboxes").update({ delta_link: cursor ?? row.delta_link, last_run_at: new Date().toISOString(), last_status: status })
    .eq("consultant_recruitcrm_id", owner);
  return { added, removed };
}

Deno.serve(async (req) => {
  if (!trustedCaller(req)) return forbidden();
  const now = new Date().toISOString();
  if (!graphConfigured()) {
    await db.from("sync_state").upsert({ entity: "inbox", last_run_at: now, last_status: "not_configured" }, { onConflict: "entity" });
    return Response.json({ ok: true, configured: false, note: "MS_TENANT_ID / MS_CLIENT_ID / MS_CLIENT_SECRET not set; nothing polled." });
  }
  const { data: boxes, error } = await db.from("inbox_mailboxes").select("*").eq("enabled", true);
  if (error) return Response.json({ ok: false, error: error.message }, { status: 500 });

  let added = 0, failed = 0;
  for (const b of boxes ?? []) {
    try { added += (await syncMailbox(b)).added; }
    catch (e) {
      failed++;
      await db.from("inbox_mailboxes").update({ last_run_at: now, last_status: `error ${String((e as Error).message).slice(0, 180)}` })
        .eq("consultant_recruitcrm_id", b.consultant_recruitcrm_id);
    }
  }
  // Counts only: the anon key that can trigger this run is public, so the response carries no mail data.
  const status = failed ? `error ${failed}/${(boxes ?? []).length} mailboxes` : `ok mailboxes=${(boxes ?? []).length} +${added}`;
  await db.from("sync_state").upsert({ entity: "inbox", last_synced_at: failed ? undefined : now, last_run_at: now, last_status: status }, { onConflict: "entity" });
  return Response.json({ ok: !failed, mailboxes: (boxes ?? []).length, added, failed });
});
