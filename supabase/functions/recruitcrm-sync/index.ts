// recruitcrm-sync — Phase 1 master-data sync (RecruitCRM → Supabase mirror).
// Entities: consultants (users), clients (companies), jobs.
// Read-only from RecruitCRM; upserts into Supabase via the service role (D6).
// Idempotent (upsert on recruitcrm_id) and resumable; robust to 429 (stops
// gracefully and returns resume_next_page instead of erroring); throttled.
//
// Deployed with verify_jwt=true — invoke server-side (cron/service role), not publicly.
//
// Query params: entity=consultants|clients|jobs, start_page (default 1), max_pages (default 1).
// Keep max_pages so a call stays under the ~60s edge wall-clock (≈80 job pages/call).

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

async function syncConsultants() {
  const r = await crm(`/users`);
  if (!r.ok) return { entity: "consultants", stopped: r.status, resume_next_page: 1 };
  const arr = Array.isArray(r.json) ? r.json : r.json?.data ?? [];
  const rows = arr.map((u: any) => ({
    recruitcrm_id: u.id, name: fullName(u), email: u.email ?? null,
    team: Array.isArray(u.teams) && u.teams.length ? (u.teams[0]?.name ?? String(u.teams[0])) : null,
    active: typeof u.status === "string" ? u.status.toLowerCase() === "active" : true,
  }));
  if (rows.length) await db.from("consultants").upsert(rows, { onConflict: "recruitcrm_id" }).throwOnError();
  return { entity: "consultants", total_upserted: rows.length, resume_next_page: null };
}

async function pageLoop(entity: string, startPage: number, maxPages: number, path: (p: number) => string, mapRow: (x: any) => any, table: string, conflict: string) {
  let page = startPage, more = true, done = 0, upserted = 0, stopped: any = null;
  while (more && done < maxPages) {
    const r = await crm(path(page));
    if (!r.ok) { stopped = r.status; break; }
    const rows = (r.json?.data ?? []).map(mapRow);
    if (rows.length) await db.from(table).upsert(rows, { onConflict: conflict }).throwOnError();
    upserted += rows.length; more = !!r.json?.next_page_url; page += 1; done += 1;
    await sleep(120);
  }
  return { entity, pages_processed: done, total_upserted: upserted, stopped, resume_next_page: (stopped || more) ? page : null };
}

async function syncJobs(startPage: number, maxPages: number) {
  const [{ data: cons }, { data: cls }] = await Promise.all([
    db.from("consultants").select("id,recruitcrm_id"),
    db.from("clients").select("id,company_slug"),
  ]);
  const consByRid = new Map((cons ?? []).map((c: any) => [c.recruitcrm_id, c.id]));
  const clientBySlug = new Map((cls ?? []).map((c: any) => [c.company_slug, c.id]));
  return pageLoop("jobs", startPage, maxPages, (p) => `/jobs?page=${p}`, (job: any) => ({
    recruitcrm_id: job.id, slug: job.slug ?? null, title: job.name ?? null,
    client_id: clientBySlug.get(job.company_slug) ?? null,
    consultant_id: consByRid.get(job.owner) ?? null,
    status: job.job_status?.label ?? (typeof job.job_status === "string" ? job.job_status : null),
    salary_min: job.min_annual_salary ?? null, salary_max: job.max_annual_salary ?? null,
    created_date: job.created_on ?? null,
  }), "jobs", "recruitcrm_id");
}

Deno.serve(async (req) => {
  try {
    if (!TOKEN) return Response.json({ error: "token not set" }, { status: 500 });
    const url = new URL(req.url);
    const entity = url.searchParams.get("entity");
    const startPage = parseInt(url.searchParams.get("start_page") ?? "1", 10);
    const maxPages = parseInt(url.searchParams.get("max_pages") ?? "1", 10);
    if (entity === "consultants") return Response.json(await syncConsultants());
    if (entity === "clients") return Response.json(await pageLoop("clients", startPage, maxPages, (p) => `/companies?page=${p}`, (c: any) => ({
      recruitcrm_id: c.id, company_name: c.company_name ?? null, company_slug: c.slug ?? null, country: c.country ?? null, active: true,
    }), "clients", "recruitcrm_id"));
    if (entity === "jobs") return Response.json(await syncJobs(startPage, maxPages));
    return Response.json({ error: "entity must be consultants|clients|jobs" }, { status: 400 });
  } catch (e) {
    return Response.json({ error: String(e) }, { status: 500 });
  }
});
