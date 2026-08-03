// recruitcrm-sync — RecruitCRM → Supabase mirror. Locked (verify_jwt=true).
// Entities: consultants, clients, jobs, candidates.
// Modes: backfill | incremental | reconcile | history (candidate_stage_events).
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
const nm = (a: any, b: any) => ([a, b].filter(Boolean).join(" ").trim() || null);

const mapConsultant = (u: any) => ({
  recruitcrm_id: u.id, name: nm(u.first_name, u.last_name), email: u.email ?? null,
  team: Array.isArray(u.teams) && u.teams.length ? (u.teams[0]?.name ?? String(u.teams[0])) : null,
  active: typeof u.status === "string" ? u.status.toLowerCase() === "active" : true,
});
const mapClient = (c: any) => ({
  recruitcrm_id: c.id, company_name: c.company_name ?? null, company_slug: c.slug ?? null, country: c.country ?? null, active: true,
});
const mapCandidate = (c: any) => ({
  recruitcrm_id: c.id, slug: c.slug ?? null, first_name: c.first_name ?? null, last_name: c.last_name ?? null,
  name: nm(c.first_name, c.last_name), email: c.email ?? null, owner_recruitcrm_id: c.owner ?? null,
  city: c.city ?? null, country: c.country ?? null, source: c.source ?? null,
  created_date: c.created_on ?? null, updated_date: c.updated_on ?? null,
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
    upserted += rows.length; more = !!r.json?.next_page_url; page += 1; done += 1; await sleep(100);
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
    const rows = (r.json?.data ?? []).map((rec: any) => {
      const upd = Date.parse(rec.updated_on ?? rec.created_on ?? "");
      if (upd) { maxSeen = Math.max(maxSeen, upd); if (upd <= since) caught = true; }
      return mapRow(rec);
    });
    if (rows.length) await db.from(table).upsert(rows, { onConflict: "recruitcrm_id" }).throwOnError();
    upserted += rows.length; more = !!r.json?.next_page_url; page += 1; done += 1; await sleep(100);
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

async function reconcilePaged(entity: string, ep: string, table: string) {
  let page = 1, more = true, done = 0, stopped: any = null; const ids: number[] = []; const CAP = 200;
  while (more && done < CAP) {
    const r = await crm(`/${ep}?page=${page}&limit=100`);
    if (!r.ok) { stopped = r.status; break; }
    for (const rec of (r.json?.data ?? [])) if (rec?.id != null) ids.push(rec.id);
    more = !!r.json?.next_page_url; page += 1; done += 1; await sleep(40);
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
async function runBg(entity: string, fn: () => Promise<any>) {
  try { const res = await fn(); await db.from("sync_state").upsert({ entity, last_run_at: new Date().toISOString(), last_status: JSON.stringify(res).slice(0, 300) }, { onConflict: "entity" }); }
  catch (e) { await db.from("sync_state").upsert({ entity, last_run_at: new Date().toISOString(), last_status: "error:" + String(e).slice(0, 200) }, { onConflict: "entity" }); }
}

// ---- history: rebuild candidate_stage_events from per-candidate /history ----
async function syncHistory(maxCandidates: number) {
  const [{ data: sl }, { data: cons }, { data: st }] = await Promise.all([
    db.from("stage_lookup").select("recruitcrm_stage_id,stage_metric,stage_name"),
    db.from("consultants").select("recruitcrm_id,name"),
    db.from("sync_state").select("cursor,last_status").eq("entity", "history").maybeSingle(),
  ]);
  if (st?.last_status === "complete") return { entity: "history", complete: true, note: "already complete" };
  const byId = new Map((sl ?? []).map((s: any) => [s.recruitcrm_stage_id, s]));
  const byLabel = new Map((sl ?? []).map((s: any) => [String(s.stage_name).toLowerCase(), s]));
  const consName = new Map((cons ?? []).map((c: any) => [c.recruitcrm_id, c.name]));
  let cursor = st?.cursor ? Number(st.cursor) : 0;

  const { data: cands } = await db.from("candidates").select("recruitcrm_id,slug,name").gt("recruitcrm_id", cursor).order("recruitcrm_id", { ascending: true }).limit(maxCandidates);
  if (!cands || cands.length === 0) {
    await db.from("sync_state").upsert({ entity: "history", last_run_at: new Date().toISOString(), last_status: "complete" }, { onConflict: "entity" });
    return { entity: "history", complete: true, processed: 0 };
  }
  let events = 0, processed = 0, skipped = 0, stopped: any = null;
  for (const cand of cands) {
    const r = await crm(`/candidates/${cand.slug}/history`);
    if (!r.ok) {
      if (r.status === 429) { stopped = 429; break; }   // back off; don't advance cursor
      skipped++; cursor = cand.recruitcrm_id; continue;   // 404/etc: skip candidate, advance
    }
    const arr = Array.isArray(r.json) ? r.json : [];
    const rows: any[] = [];
    for (const e of arr) {
      const s = byId.get(e.candidate_status_id) ?? byLabel.get(String(e.candidate_status ?? "").toLowerCase());
      if (!s || !e.updated_on || !e.job_slug) continue;
      rows.push({
        candidate_id: cand.recruitcrm_id, candidate_slug: cand.slug, candidate_name: cand.name,
        job_slug: e.job_slug, job_title: e.job_name ?? null,
        consultant_id: e.updated_by ?? null, consultant: consName.get(e.updated_by) ?? null,
        stage_name: s.stage_name, stage_metric: s.stage_metric,
        event_timestamp: e.updated_on, event_date: String(e.updated_on).slice(0, 10),
      });
    }
    if (rows.length) await db.from("candidate_stage_events").upsert(rows, { onConflict: "candidate_slug,job_slug,stage_metric,event_timestamp" }).throwOnError();
    events += rows.length; processed++; cursor = cand.recruitcrm_id; await sleep(50);
  }
  await db.from("sync_state").upsert({ entity: "history", cursor: String(cursor), last_run_at: new Date().toISOString(), last_status: stopped ? `stopped:${stopped}@${cursor}` : `cursor=${cursor} +${events}ev` }, { onConflict: "entity" });
  return { entity: "history", processed, skipped, events, cursor, stopped };
}

Deno.serve(async (req) => {
  try {
    if (!TOKEN) return Response.json({ error: "token not set" }, { status: 500 });
    const url = new URL(req.url);
    const mode = url.searchParams.get("mode") ?? "backfill";
    const entity = url.searchParams.get("entity") ?? "all";

    if (mode === "history") {
      const maxC = parseInt(url.searchParams.get("max_candidates") ?? "70", 10);
      return Response.json(await syncHistory(maxC));
    }

    if (mode === "incremental") {
      const out: any = { mode: "incremental", results: [] };
      if (entity === "all" || entity === "consultants") out.results.push(await syncConsultants());
      if (entity === "all" || entity === "clients") out.results.push(await incremental("clients", "companies", mapClient, "clients"));
      if (entity === "all" || entity === "candidates") out.results.push(await incremental("candidates", "candidates", mapCandidate, "candidates"));
      if (entity === "all" || entity === "jobs") { const [cb, sb] = await jobMaps(); out.results.push(await incremental("jobs", "jobs", mapJobFactory(cb, sb), "jobs")); }
      return Response.json(out);
    }

    if (mode === "reconcile") {
      if (entity === "consultants") return Response.json(await reconcileConsultants());
      const fn = entity === "clients" ? () => reconcilePaged("clients", "companies", "clients")
               : entity === "candidates" ? () => reconcilePaged("candidates", "candidates", "candidates")
               : entity === "jobs" ? () => reconcilePaged("jobs", "jobs", "jobs") : null;
      if (!fn) return Response.json({ error: "reconcile needs entity=consultants|clients|candidates|jobs" }, { status: 400 });
      try { (globalThis as any).EdgeRuntime?.waitUntil(runBg(`reconcile:${entity}`, fn)); } catch {}
      return Response.json({ mode: "reconcile", entity, status: "started (background)" }, { status: 202 });
    }

    const startPage = parseInt(url.searchParams.get("start_page") ?? "1", 10);
    const maxPages = parseInt(url.searchParams.get("max_pages") ?? "1", 10);
    if (entity === "consultants") return Response.json(await syncConsultants());
    if (entity === "clients") return Response.json(await backfillLoop("clients", startPage, maxPages, "companies", mapClient, "clients"));
    if (entity === "candidates") return Response.json(await backfillLoop("candidates", startPage, maxPages, "candidates", mapCandidate, "candidates"));
    if (entity === "jobs") { const [cb, sb] = await jobMaps(); return Response.json(await backfillLoop("jobs", startPage, maxPages, "jobs", mapJobFactory(cb, sb), "jobs")); }
    return Response.json({ error: "entity must be consultants|clients|candidates|jobs" }, { status: 400 });
  } catch (e) {
    return Response.json({ error: String(e) }, { status: 500 });
  }
});
