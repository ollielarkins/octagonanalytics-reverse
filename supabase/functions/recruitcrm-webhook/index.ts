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

// Map a keyword found in the payload to a recruitcrm-sync entity. First match wins; else "all".
function routeEntity(text: string): string {
  const t = text.toLowerCase();
  if (/\bdeal\b|deal_stage|deal_value/.test(t)) return "deals";
  if (/candidate|hiring|stage|placement/.test(t)) return "candidates";
  if (/\bjob\b|job_slug|vacancy/.test(t)) return "jobs";
  if (/company|contact|client/.test(t)) return "clients";
  if (/call|devyce|call_log/.test(t)) return "calls";
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

  const hintText = bodyText || JSON.stringify(raw ?? {});
  const entity = routeEntity(hintText);
  const eventHint = (raw && (raw.event ?? raw.event_type ?? raw.type ?? raw.action)) ?? null;

  // Log first (so we always capture the payload shape), then fire the sync in the background and ACK fast.
  try {
    await db.from("webhook_events").insert({ event_hint: eventHint ? String(eventHint).slice(0, 120) : null, routed_entity: entity, raw, ok: true });
  } catch (_e) { /* non-fatal */ }

  try { (globalThis as any).EdgeRuntime?.waitUntil(fireSync(entity)); }
  catch { await fireSync(entity); }

  return Response.json({ ok: true, routed_entity: entity }, { status: 200 });
});
