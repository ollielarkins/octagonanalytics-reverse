// recruitcrm-sync — RecruitCRM → Supabase mirror. Locked (verify_jwt=true).
// Modes: backfill (entity,start_page,max_pages) | incremental (?mode=incremental)
//        | reconcile (?mode=reconcile&entity=jobs|clients|consultants) — soft-
//          deletes mirror rows no longer present in RecruitCRM (delete detection).
import { createClient } from "jsr:@supabase/supabase-js@2";

const BASE = "https://api.recruitcrm.io/v1";
const TOKEN = (Deno.env.get("RECRUIT_CRM_API_TOKEN") ?? Deno.env.get("RECRUITCRM_API_TOKEN") ?? "").trim();
const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function crm(path: string) {
  const res = await fetch(`${BASE}${path}`, { headers: { Authorization: `Bearer ${TOKEN}`, Accept: "application/json" } });
  const text = await res.text();
  let json: any = null; try { json = JSON.parse(text); } catch {}
  return { ok: res.ok, status: res.status, json, text };
}
const fullName = (u: any) => ([u.first_name, u.last_name].filter(Boolean).join(" ").trim() || null);

const mapConsultant = (u: any) => ({
  recruitcrm_id: u.id, name: fullName(u), email: u.email ?? null,
  team: Array.isArray(u.teams) && u.teams.length ? (u.teams[0]?.name ?? String(u.teams[0])) : null,
  active: typeof u.status === "string" ? u.status.toLowerCase() === "active" : true,
});
const mapClient = (c: any) => ({
  recruitcrm_id: c.id, company_name: c.company_name ?? null, company_slug: c.slug ?? null, country: c.country ?? null, active: true,
});
function mapJobFactory(consByRid: Map<any, any>, clientBySlug: Map<any, any>) {
  return (job: any) => ({
    recruitcrm_id: job.id, slug: job.slug ?? null, title: job.name ?? null,
    client_id: clientBySlug.get(job.company_slug) ?? null,
    consultant_id: consByRid.get(job.owner) ?? null,
    status: job.job_status?.label ?? (typeof job.job_status === "string" ? job.job_status : null),
    salary_min: job.min_annual_salary ?? null, salary_max: job.max_annual_salary ?? null,
    created_date: job.created_on ?? null,
  });
}
async function jobMaps() {
  const [{ data: cons }, { data: cls }] = await Promise.all([
    db.from("consultants").select("id,recruitcrm_id"),
    db.from("clients").select("id,company_slug"),
  ]);
  return [new Map((cons ?? []).map((c: any) => [c.recruitcrm_id, c.id])), new Map((cls ?? []).map((c: any) => [c.company_slug, c.id]))] as const;
}

async function backfillLoop(entity: string, startPage: number, maxPages: number, ep: string, mapRow: (x: any) => any, table: string) {
  let page = startPage, more = true, done = 0, upserted = 0, stopped: any = null;
  while (more && done < maxPages) {
    const r = await crm(`/${ep}?page=${page}&limit=100`);
    if (!r.ok) { stopped = r.status; break; }
    const rows = (r.json?.data ?? []).map(mapRow);
    if (rows.length) await db.from(table).upsert(rows, { onConflict: "recruitcrm_id" }).throwOnError();
    upserted += rows.length; more = !!r.json?.next_page_url; page += 1; done += 1; await sleep(120);
  }
  return { entity, pages_processed: done, total_upserted: upserted, stopped, resume_next_page: (stopped || more) ? page : null };
}

async function incremental(entity: string, ep: string, mapRow: (x: any) => any, table: string) {
  const { data: st } = await db.from("sync_state").select("last_synced_at").eq("entity", entity).maybeSingle();
  const since = st?.last_synced_at ? Date.parse(st.last_synced_at) : 0;
  let page = 1, more = true, caught = false, upserted = 0, maxSeen = since, stopped: any = null, done = 0;
  const CAP = 40;
  while (more && !caught && done < CAP) {
    const r = await crm(`/${ep}?page=${page}&sort_by=updatedon&sort_order=desc&limit=100`);
    if (!r.ok) { stopped = r.status; break; }
    const recs = r.json?.data ?? [];
    const rows = recs.map((rec: any) => {
      const upd = Date.parse(rec.updated_on ?? rec.created_on ?? "");
      if (upd) { maxSeen = Math.max(maxSeen, upd); if (upd <= since) caught = true; }
      return mapRow(rec);
    });
    if (rows.length) await db.from(table).upsert(rows, { onConflict: "recruitcrm_id" }).throwOnError();
    upserted += rows.length; more = !!r.json?.next_page_url; page += 1; done += 1; await sleep(120);
  }
  const newSince = new Date(Math.max(maxSeen, since)).toISOString();
  await db.from("sync_state").upsert({ entity, last_synced_at: newSince, last_run_at: new Date().toISOString(), last_status: stopped ? `stopped:${stopped}` : caught ? "caught_up" : "page_cap" }, { onConflict: "entity" });
  return { entity, pages: done, upserted, caught, stopped };
}

async function syncConsultants() {
  const r = await crm(`/users`);
  if (!r.ok) return { entity: "consultants", stopped: r.status };
  const arr = Array.isArray(r.json) ? r.json : r.json?.data ?? [];
  const rows = arr.map(mapConsultant);
  if (rows.length) await db.from("consultants").upsert(rows, { onConflict: "recruitcrm_id" }).throwOnError();
  await db.from("sync_state").upsert({ entity: "consultants", last_synced_at: new Date().toISOString(), last_run_at: new Date().toISOString(), last_status: "ok" }, { onConflict: "entity" });
  return { entity: "consultants", upserted: rows.length };
}

// ---- reconcile (delete detection): collect COMPLETE live id set, soft-delete missing ----
async function reconcilePaged(entity: string, ep: string, table: string) {
  let page = 1, more = true, done = 0, stopped: any = null; const ids: number[] = []; const CAP = 120;
  while (more && done < CAP) {
    const r = await crm(`/${ep}?page=${page}&limit=100`);
    if (!r.ok) { stopped = r.status; break; }
    for (const rec of (r.json?.data ?? [])) if (rec?.id != null) ids.push(rec.id);
    more = !!r.json?.next_page_url; page += 1; done += 1; await sleep(80);
  }
  const complete = !stopped && !more;
  if (!complete) return { entity, complete: false, stopped, pages: done, live_ids: ids.length, note: "partial fetch — reconcile skipped" };
  const { data, error } = await db.rpc("reconcile_entity", { p_table: table, p_live_ids: ids });
  return { entity, complete: true, pages: done, live_ids: ids.length, result: error ? String(error.message) : data };
}
async function reconcileConsultants() {
  const r = await crm(`/users`);
  if (!r.ok) return { entity: "consultants", complete: false, stopped: r.status };
  const arr = Array.isArray(r.json) ? r.json : r.json?.data ?? [];
  const ids = arr.map((u: any) => u.id).filter((x: any) => x != null);
  const { data, error } = await db.rpc("reconcile_entity", { p_table: "consultants", p_live_ids: ids });
  return { entity: "consultants", complete: true, live_ids: ids.length, result: error ? String(error.message) : data };
}

Deno.serve(async (req) => {
  try {
    if (!TOKEN) return Response.json({ error: "token not set" }, { status: 500 });
    const url = new URL(req.url);
    const mode = url.searchParams.get("mode") ?? "backfill";
    const entity = url.searchParams.get("entity") ?? "all";

    if (mode === "incremental") {
      const out: any = { mode: "incremental", results: [] };
      if (entity === "all" || entity === "consultants") out.results.push(await syncConsultants());
      if (entity === "all" || entity === "clients") out.results.push(await incremental("clients", "companies", mapClient, "clients"));
      if (entity === "all" || entity === "jobs") { const [cb, sb] = await jobMaps(); out.results.push(await incremental("jobs", "jobs", mapJobFactory(cb, sb), "jobs")); }
      return Response.json(out);
    }

    if (mode === "reconcile") {
      if (entity === "consultants") return Response.json(await reconcileConsultants());
      if (entity === "clients") return Response.json(await reconcilePaged("clients", "companies", "clients"));
      if (entity === "jobs") return Response.json(await reconcilePaged("jobs", "jobs", "jobs"));
      return Response.json({ error: "reconcile needs entity=consultants|clients|jobs" }, { status: 400 });
    }

    // backfill
    const startPage = parseInt(url.searchParams.get("start_page") ?? "1", 10);
    const maxPages = parseInt(url.searchParams.get("max_pages") ?? "1", 10);
    if (entity === "consultants") return Response.json(await syncConsultants());
    if (entity === "clients") return Response.json(await backfillLoop("clients", startPage, maxPages, "companies", mapClient, "clients"));
    if (entity === "jobs") { const [cb, sb] = await jobMaps(); return Response.json(await backfillLoop("jobs", startPage, maxPages, "jobs", mapJobFactory(cb, sb), "jobs")); }
    return Response.json({ error: "entity must be consultants|clients|jobs" }, { status: 400 });
  } catch (e) {
    return Response.json({ error: String(e) }, { status: 500 });
  }
});
