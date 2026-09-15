// recruitcrm-webhook — near-real-time freshness. RecruitCRM POSTs here on any change; we verify a
// shared secret, log the event, best-effort route it to an entity, and fire the existing incremental
// sync (which pulls the just-changed record, newest-first). Reuses all recruitcrm-sync logic — the
// webhook is a "something changed -> sync now" trigger, not a data source, so it doesn't depend on
// the exact RecruitCRM payload shape. verify_jwt=false; auth is the ?key= secret.
import { createClient } from "jsr:@supabase/supabase-js@2";

const SB = Deno.env.get("SUPABASE_URL")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const SECRET = (Deno.env.get("WEBHOOK_SECRET") ?? "").trim();
const db = createClient(SB, SERVICE);

// Route a payload to a recruitcrm-sync entity.
//
// This used to keyword-scan the whole body in a fixed order, and it was wrong in a way that hid
// itself for months: a JOB payload contains "note_for_candidates" and "additional_candidates", so it
// matched the candidate rule before ever reaching the job rule. Measured over the events held on
// 15/09/2026: 68 job payloads and 16 company payloads were routed to "candidates", and 86 candidate
// payloads to "deals". Each one fired an incremental sync for the WRONG entity, so a job edit
// refreshed candidates and left the job itself to the 15-minute poll - which is why jobs looked like
// they had no webhook at all.
//
// Now: trust the subscription's own event name when it is there (we set ?event= on the target_url we
// register), and otherwise classify on distinctive TOP-LEVEL KEYS rather than words appearing
// anywhere in the body. The key sets are near-disjoint in practice.
function routeEntity(raw: any, evParam: string | null): string {
  if (evParam) {
    const k = evParam.split(".")[0];
    if (k === "candidate") return "candidates";
    if (k === "job") return "jobs";
    if (k === "company" || k === "contact") return "clients";
    if (k === "deal") return "deals";
    if (k === "calllog") return "calls";
  }
  const o = (raw && typeof raw === "object") ? raw : {};
  if ("deal_stage" in o || "deal_value" in o) return "deals";
  if ("job_status" in o || "job_code" in o) return "jobs";
  if ("company_name" in o) return "clients";
  if ("call_type" in o || "call_started_on" in o) return "calls";
  if ("first_name" in o || "candidate_summary" in o) return "candidates";
  return "all";
}

async function fireSync(entity: string) {
  const url = `${SB}/functions/v1/recruitcrm-sync?mode=incremental&entity=${encodeURIComponent(entity)}`;
  try { await fetch(url, { headers: { Authorization: `Bearer ${SERVICE}` } }); } catch (_e) { /* logged by caller */ }
}

Deno.serve(async (req) => {
  const url = new URL(req.url);
  const key = url.searchParams.get("key") ?? req.headers.get("x-webhook-key") ?? "";
  if (!SECRET || key !== SECRET) return new Response("unauthorized", { status: 401 });

  // A GET is treated as a health/verification ping.
  if (req.method === "GET") return Response.json({ ok: true, service: "recruitcrm-webhook" });

  let raw: any = null; let bodyText = "";
  try { bodyText = await req.text(); raw = bodyText ? JSON.parse(bodyText) : null; } catch { /* keep bodyText */ }

  // RecruitCRM does not name the event in the body: all 1,973 events received to date carry no
  // event/type/action field, which is why event_hint was always null. We choose the target_url per
  // subscription, so the name rides on the URL instead (?event=job.deleted).
  const evParam = (url.searchParams.get("event") ?? "").trim() || null;
  const entity = routeEntity(raw, evParam);
  const eventHint = evParam ?? (raw && (raw.event ?? raw.event_type ?? raw.type ?? raw.action)) ?? null;

  // Log first (so we always capture the payload shape), then act and ACK fast.
  try {
    await db.from("webhook_events").insert({ event_hint: eventHint ? String(eventHint).slice(0, 120) : null, routed_entity: entity, raw, ok: true });
  } catch (_e) { /* non-fatal */ }

  // A delete is the one event the incremental sync cannot act on: it only walks records that still
  // EXIST, so a deleted record is never in the list and the sync does nothing at all. The row then
  // survives until a reconcile page-walk notices it - up to an hour. Tombstone it here instead.
  if (evParam && evParam.endsWith(".deleted")) {
    const kind = evParam.split(".")[0];
    const target: Record<string, { table: string; col: string }> = {
      candidate: { table: "candidates", col: "slug" },
      job:       { table: "jobs",       col: "slug" },
      company:   { table: "clients",    col: "company_slug" },
      deal:      { table: "deals",      col: "slug" },
    };
    const t = target[kind];
    const slug = raw?.slug ?? raw?.[kind + "_slug"] ?? null;
    let tombstoned: any = null;
    if (t && slug) {
      try {
        const { data, error } = await db.from(t.table)
          .update({ deleted_at: new Date().toISOString() })
          .eq(t.col, String(slug)).is("deleted_at", null).select(t.col);
        tombstoned = error ? ("error:" + error.message) : (data?.length ?? 0);
      } catch (e) { tombstoned = "error:" + String(e).slice(0, 120); }
    }
    // No sync fired: there is nothing left upstream to pull.
    return Response.json({ ok: true, event: evParam, slug: slug ?? null, tombstoned }, { status: 200 });
  }

  try { (globalThis as any).EdgeRuntime?.waitUntil(fireSync(entity)); }
  catch { await fireSync(entity); }

  return Response.json({ ok: true, routed_entity: entity, event: eventHint }, { status: 200 });
});
