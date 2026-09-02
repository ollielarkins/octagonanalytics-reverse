// recruitcrm-sync — RecruitCRM → Supabase mirror. Locked (verify_jwt=true).
// Entities: consultants, clients, jobs, candidates, calls (call_activity via /call-logs), deals.
// Modes: backfill | backfill_all | incremental | reconcile | history (candidate_stage_events).
// deals feeds the billing report (Won deal_value); owner-attributed via deals.owner_recruitcrm_id.
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

// RecruitCRM's paged lists can return the same record twice inside a single page - its ordering
// shifts as records are updated mid-walk. Postgres rejects an INSERT ... ON CONFLICT whose batch
// contains the same conflict key twice ("cannot affect row a second time") and fails the WHOLE
// page, not just the duplicate. That killed the candidate backfill at page ~253 of 518 on
// 01/09/2026. Keep the last occurrence of each key.
function dedupeBy(rows: any[], keyOf: (r: any) => any) {
  const m = new Map<any, any>();
  for (const r of rows) { const k = keyOf(r); if (k != null) m.set(k, r); }
  return [...m.values()];
}
const byRecruitcrmId = (r: any) => r?.recruitcrm_id;

const mapConsultant = (u: any) => ({
  recruitcrm_id: u.id, name: nm(u.first_name, u.last_name), email: u.email ?? null,
  team: Array.isArray(u.teams) && u.teams.length ? (u.teams[0]?.name ?? String(u.teams[0])) : null,
  active: typeof u.status === "string" ? u.status.toLowerCase() === "active" : true,
});
function customField(obj: any, nameRe: RegExp) {
  const arr = Array.isArray(obj?.custom_fields) ? obj.custom_fields : [];
  const f = arr.find((x: any) => nameRe.test(String(x?.field_name ?? x?.label ?? x?.name ?? "")));
  const v = f ? (f.value ?? f.field_value ?? f.val ?? null) : null;
  return (v != null && String(v).trim() !== "") ? String(v).trim() : null;
}
// Custom fields arrive as text. Strip currency symbols, commas and % before casting.
function numField(obj: any, nameRe: RegExp) {
  const s = customField(obj, nameRe);
  if (s == null) return null;
  const n = Number(s.replace(/[^0-9.\-]/g, ""));
  return Number.isFinite(n) ? n : null;
}
// Don't hand ambiguous strings to Date(): "05/08/2026" is 5 August here and 8 May to JS.
function dateField(obj: any, nameRe: RegExp) {
  const s = customField(obj, nameRe);
  if (s == null) return null;
  const dmy = /^(\d{1,2})[\/.-](\d{1,2})[\/.-](\d{4})$/.exec(s);
  if (dmy) return `${dmy[3]}-${dmy[2].padStart(2, "0")}-${dmy[1].padStart(2, "0")}`;
  const iso = /^(\d{4}-\d{2}-\d{2})/.exec(s);
  return iso ? iso[1] : null;
}
const mapClient = (c: any) => ({
  recruitcrm_id: c.id, company_name: c.company_name ?? null, company_slug: c.slug ?? null, country: c.country ?? null, active: true,
  company_status: customField(c, /company status/i),
});
const mapCandidate = (c: any) => ({
  recruitcrm_id: c.id, slug: c.slug ?? null, first_name: c.first_name ?? null, last_name: c.last_name ?? null,
  name: nm(c.first_name, c.last_name), email: c.email ?? null, owner_recruitcrm_id: c.owner ?? null,
  city: c.city ?? null, country: c.country ?? null, source: c.source ?? null,
  skill: Array.isArray(c.skill) ? c.skill.join(", ") : (c.skill ?? null),
  created_date: c.created_on ?? null, updated_date: c.updated_on ?? null,
  // Stamped on every list sync. A row not stamped during a completed backfill pass no longer
  // exists in RecruitCRM - see retire_unseen_candidates().
  last_seen_at: new Date().toISOString(),
});
function mapCallFactory(consName: Map<any, any>) {
  return (x: any) => ({
    recruitcrm_id: x.id,
    call_type: x.call_type ?? null,
    custom_call_type: x.custom_call_type?.label ?? (typeof x.custom_call_type === "string" ? x.custom_call_type : null),
    call_started_on: x.call_started_on ?? null,
    call_date: x.call_started_on ? String(x.call_started_on).slice(0, 10) : null,
    duration_seconds: typeof x.duration === "number" ? x.duration : null,
    connected: typeof x.duration === "number" ? x.duration > 0 : null,
    consultant_recruitcrm_id: x.created_by ?? null,
    consultant: consName.get(x.created_by) ?? null,
    related_to: x.related_to ?? null,
    related_to_type: x.related_to_type ?? null,
  });
}
async function consNameMap() {
  const { data } = await db.from("consultants").select("recruitcrm_id,name");
  return new Map((data ?? []).map((c: any) => [c.recruitcrm_id, c.name]));
}
function mapJobFactory(consByRid: Map<any, any>, clientBySlug: Map<any, any>) {
  return (job: any) => ({
    recruitcrm_id: job.id, slug: job.slug ?? null, title: job.name ?? null,
    // Keep the raw company_slug even when it doesn't resolve, so an unresolved job can be repaired
    // later instead of losing its only link to the company.
    company_slug: job.company_slug ?? null,
    client_id: clientBySlug.get(job.company_slug) ?? null,
    consultant_id: consByRid.get(job.owner) ?? null,
    status: job.job_status?.label ?? (typeof job.job_status === "string" ? job.job_status : null),
    salary_min: job.min_annual_salary ?? null, salary_max: job.max_annual_salary ?? null,
    created_date: job.created_on ?? null,
    forecast_fee: numField(job, /^forecast fee/i),   // "Forecast Fee (£)" — per-role forward indicator
  });
}
const mapDeal = (d: any) => ({
  recruitcrm_id: d.id,
  slug: d.slug ?? null,          // keyed by slug on the write endpoints (0050)
  deal_name: d.name ?? null,
  deal_stage: d.deal_stage?.label ?? (typeof d.deal_stage === "string" ? d.deal_stage : null),
  deal_value: typeof d.deal_value === "number" ? d.deal_value : (d.deal_value != null ? Number(d.deal_value) : null),
  close_date: d.close_date ?? null,
  deal_type: d.deal_type?.label ?? (typeof d.deal_type === "string" ? d.deal_type : null),
  company_slug: d.company_slug ?? null,
  job_slug: d.job_slug ?? null,
  owner_recruitcrm_id: d.owner ?? null,
  created_date: d.created_on ?? null,
  updated_date: d.updated_on ?? null,
  resource_url: d.resource_url ?? null,
  // Fee components (0043). Anchored regexes: /annual salary/ alone would also match
  // "Percentage of Annual Salary" and silently put the percentage in the salary column.
  annual_salary: numField(d, /^annual salary$/i),
  fee_percentage: numField(d, /^percentage of annual salary$/i),
  fee_currency: customField(d, /^currency$/i),
  start_date: dateField(d, /^start date$/i),
  end_date: dateField(d, /^end date$/i),
});
const mapNote = (n: any) => ({
  recruitcrm_id: n.id,
  note_type: n.note_type?.label ?? (typeof n.note_type === "string" ? n.note_type : null),
  // Strip the HTML RecruitCRM stores so the text is usable in reports and search.
  description: typeof n.description === "string" ? n.description.replace(/<[^>]+>/g, " ").replace(/\s+/g, " ").trim().slice(0, 4000) : null,
  related_to: n.related_to ?? null,
  related_to_type: n.related_to_type ?? null,
  consultant_recruitcrm_id: n.created_by ?? null,
  created_on: n.created_on ?? null,
  updated_on: n.updated_on ?? null,
});

// Off-limit is a small, separate list (~88 rows) rather than a field on the candidate list, so it
// gets its own pass: clear the flags, then set them from the live list. Guarded — an empty or failed
// fetch leaves the existing flags alone rather than marking everyone approachable.
async function syncOffLimit() {
  const r = await crm(`/candidates/off-limit?limit=100`);
  if (!r.ok) return { entity: "offlimit", error: r.status };
  const inner = r.json?.data ?? r.json;
  const rows = Array.isArray(inner) ? inner : (inner?.records ?? []);
  if (!rows.length) return { entity: "offlimit", skipped: true, reason: "empty list — flags left untouched" };
  const slugs = rows.map((c: any) => c.slug).filter(Boolean);
  await db.from("candidates").update({ off_limit: false, off_limit_until: null, off_limit_reason: null })
    .eq("off_limit", true).throwOnError();
  // Count how many actually matched a mirrored candidate. RecruitCRM can hold off-limit people we
  // have never synced; those cannot be flagged — but they also cannot appear in match_candidates,
  // which reads the same mirror, so the filter stays complete for anything we can surface.
  let matched = 0;
  for (const c of rows) {
    if (!c.slug) continue;
    const { data: upd } = await db.from("candidates").update({
      off_limit: true,
      off_limit_until: c.off_limit_end_date ? String(c.off_limit_end_date).slice(0, 10) : null,
      off_limit_reason: c.off_limit_reason ?? null,
    }).eq("slug", c.slug).select("slug");
    if (upd?.length) matched++;
  }
  await db.from("sync_state").upsert({ entity: "offlimit", last_run_at: new Date().toISOString(),
    last_status: `off_limit=${slugs.length} matched=${matched}`, last_synced_at: new Date().toISOString() }, { onConflict: "entity" });
  return { entity: "offlimit", off_limit_in_crm: slugs.length, flagged_in_mirror: matched, not_mirrored: slugs.length - matched };
}

// PostgREST caps an unbounded select at 1,000 rows. `clients` holds ~4,600, so the lookup map was
// silently missing three quarters of them and every job whose company fell outside the first page
// had its client_id resolved to null on write. That is the real cause of the "orphaned jobs" —
// not archived companies. Page explicitly.
async function allRows(table: string, cols: string) {
  const out: any[] = [];
  const size = 1000;
  for (let from = 0; ; from += size) {
    const { data, error } = await db.from(table).select(cols).range(from, from + size - 1);
    if (error) throw error;
    if (!data?.length) break;
    out.push(...data);
    if (data.length < size) break;
  }
  return out;
}
async function jobMaps() {
  const [cons, cls] = await Promise.all([
    allRows("consultants", "id,recruitcrm_id"),
    allRows("clients", "id,company_slug"),
  ]);
  return [new Map(cons.map((c: any) => [c.recruitcrm_id, c.id])), new Map(cls.map((c: any) => [c.company_slug, c.id]))] as const;
}

async function backfillLoop(entity: string, startPage: number, maxPages: number, ep: string, mapRow: (x: any) => any, table: string) {
  let page = startPage, more = true, done = 0, upserted = 0, stopped: any = null, dupes = 0;
  while (more && done < maxPages) {
    const r = await crm(`/${ep}?page=${page}&limit=100`);
    if (!r.ok) { stopped = r.status; break; }
    const raw = (r.json?.data ?? []).map(mapRow);
    const rows = dedupeBy(raw, byRecruitcrmId);
    dupes += raw.length - rows.length;
    if (rows.length) await db.from(table).upsert(rows, { onConflict: "recruitcrm_id" }).throwOnError();
    upserted += rows.length; more = !!r.json?.next_page_url; page += 1; done += 1; await sleep(100);
  }
  return { entity, pages_processed: done, total_upserted: upserted, dupes_dropped: dupes, stopped, resume_next_page: (stopped || more) ? page : null };
}

async function incremental(entity: string, ep: string, mapRow: (x: any) => any, table: string) {
  const { data: st } = await db.from("sync_state").select("last_synced_at").eq("entity", entity).maybeSingle();
  const since = st?.last_synced_at ? Date.parse(st.last_synced_at) : 0;
  let page = 1, more = true, caught = false, upserted = 0, maxSeen = since, stopped: any = null, done = 0, noId = 0;
  const CAP = 40;
  while (more && !caught && done < CAP) {
    const r = await crm(`/${ep}?page=${page}&sort_by=updatedon&sort_order=desc&limit=100`);
    if (!r.ok) { stopped = r.status; break; }
    const raw: any[] = [];
    for (const rec of (r.json?.data ?? [])) {
      const upd = Date.parse(rec.updated_on ?? rec.created_on ?? "");
      if (upd) { maxSeen = Math.max(maxSeen, upd); if (upd <= since) caught = true; }
      // A record with no usable id cannot be keyed. On 21/08/2026 RecruitCRM served a freshly
      // created candidate with id 0; we mirrored it, and because that row then owned the slug,
      // every later run tried to INSERT the real record — ON CONFLICT(recruitcrm_id) never
      // matched — and hit candidates_slug_key instead. One row froze jobs and calls for eleven
      // days. Skip what we cannot key rather than writing a placeholder id.
      if (rec?.id == null || rec.id === 0) { noId += 1; continue; }
      raw.push(mapRow(rec));
    }
    const rows = dedupeBy(raw, byRecruitcrmId);
    if (rows.length) await db.from(table).upsert(rows, { onConflict: "recruitcrm_id" }).throwOnError();
    upserted += rows.length; more = !!r.json?.next_page_url; page += 1; done += 1; await sleep(100);
  }
  const newSince = new Date(Math.max(maxSeen, since)).toISOString();
  await db.from("sync_state").upsert({ entity, last_synced_at: newSince, last_run_at: new Date().toISOString(), last_status: stopped ? `stopped:${stopped}` : caught ? "caught_up" : "page_cap" }, { onConflict: "entity" });
  return { entity, pages: done, upserted, caught, stopped, skipped_no_id: noId };
}

async function syncConsultants() {
  const r = await crm(`/users`);
  if (!r.ok) return { entity: "consultants", stopped: r.status };
  const arr = Array.isArray(r.json) ? r.json : r.json?.data ?? [];
  const rows = dedupeBy(arr.map(mapConsultant), byRecruitcrmId);
  if (rows.length) await db.from("consultants").upsert(rows, { onConflict: "recruitcrm_id" }).throwOnError();
  await db.from("sync_state").upsert({ entity: "consultants", last_synced_at: new Date().toISOString(), last_run_at: new Date().toISOString(), last_status: "ok" }, { onConflict: "entity" });
  return { entity: "consultants", upserted: rows.length };
}

async function reconcilePaged(entity: string, ep: string, table: string) {
  // 200 pages = 20,000 records. RecruitCRM holds ~51,700 candidates, so the old cap meant the
  // candidates reconcile could NEVER complete: it would fetch 20,000, see more remaining, and
  // correctly refuse to act - but keep reporting a fresh last_run_at, so health showed green while
  // it did nothing at all. 600 pages = 60,000, with headroom.
  let page = 1, more = true, done = 0, stopped: any = null; const ids: number[] = []; const CAP = 600;
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
async function reconcileDeals() {
  let page = 1, more = true, done = 0, stopped: any = null; const ids: number[] = []; const CAP = 80;
  while (more && done < CAP) {
    const r = await crm(`/deals?page=${page}&limit=100`);
    if (!r.ok) { stopped = r.status; break; }
    for (const rec of (r.json?.data ?? [])) if (rec?.id != null) ids.push(rec.id);
    more = !!r.json?.next_page_url; page += 1; done += 1; await sleep(40);
  }
  // Guard: never reconcile on a partial or empty fetch (would hard-delete live deals).
  if (stopped || more || !ids.length) return { entity: "deals", complete: false, stopped, pages: done, live_ids: ids.length, note: "partial/empty — reconcile skipped" };
  const { data, error } = await db.rpc("reconcile_deals", { p_live_ids: ids });
  return { entity: "deals", complete: true, pages: done, live_ids: ids.length, result: error ? String(error.message) : data };
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

// ---- history: candidate_stage_events, rebuilt from per-candidate /history -------------------
//
// Two modes, because these are genuinely different jobs:
//   history         one-off backfill. Walks every candidate by id, latches "complete" when done.
//   history_recent  the ONGOING feed. Walks only candidates changed in the last N days.
//
// The ongoing feed was missing entirely until 10/08/2026 and nobody noticed for six days. The
// backfill latched "complete" on 04/08 and the every-minute cron short-circuited from then on, so
// candidate_stage_events — the single source for the whole funnel — simply stopped. Stage-change
// webhooks fire entity=candidates, which refreshes the candidate ROW; they never touched the event
// stream. A full re-walk is 16,600 API calls, but only ~500 candidates change in a week, so the
// recent walk is the right shape for keeping up.
// Self-resuming full backfill for candidates.
//
// The candidate mirror held 17,346 of RecruitCRM's ~51,700 - the original backfill was never driven
// to completion, and because backfillLoop defaults to ONE page (100 records) per call, finishing it
// means ~518 chained invocations. Doing that by hand through pg_net does not work: a 90-page chunk
// takes over 55s and the caller times out mid-flight, and pg_net then fails DNS under its own load.
//
// So: run in the background (the response returns immediately, so no caller timeout) and persist
// resume_next_page in sync_state.cursor, so each invocation continues where the last one stopped.
async function backfillCandidatesResumable(startPageParam: string | null, maxPages: number) {
  const key = "backfill:candidates";
  const { data: st } = await db.from("sync_state").select("cursor,last_status,last_synced_at").eq("entity", key).maybeSingle();
  const done = st?.last_status?.startsWith("complete") || st?.last_status?.includes('"complete":true');
  if (done && !startPageParam) return { entity: "candidates", complete: true, note: "already complete" };

  // A pass starts when we are handed an explicit start_page, or when there is no cursor to resume.
  // last_synced_at carries that pass's start time across the several invocations a full pass takes.
  const fresh = !!startPageParam || !st?.cursor;
  const from = parseInt(startPageParam ?? st?.cursor ?? "1", 10);
  const passStart = (!fresh && st?.last_synced_at) ? st.last_synced_at : new Date().toISOString();

  const res = await backfillLoop("candidates", from, maxPages, "candidates", mapCandidate, "candidates");
  const complete = !res.resume_next_page;

  // Only a COMPLETE pass can retire anything: a partial pass has not seen the whole live list, so
  // every unstamped row would look deleted. Same reasoning as reconcilePaged's partial-fetch guard.
  let retired: any = null;
  if (complete) {
    const { data, error } = await db.rpc("retire_unseen_candidates", { p_pass_start: passStart });
    retired = error ? `error:${error.message}` : data;
  }

  await db.from("sync_state").upsert({
    entity: key,
    cursor: res.resume_next_page ? String(res.resume_next_page) : null,
    last_synced_at: complete ? new Date().toISOString() : passStart,
    last_run_at: new Date().toISOString(),
    last_status: complete ? `complete retired=${retired}` : `page=${res.resume_next_page} +${res.total_upserted}`,
  }, { onConflict: "entity" });
  return { ...res, started_at_page: from, pass_start: passStart, complete, retired };
}

async function historyMaps() {
  const [{ data: sl }, cons] = await Promise.all([
    db.from("stage_lookup").select("recruitcrm_stage_id,stage_metric,stage_name"),
    allRows("consultants", "recruitcrm_id,name"),
    allRows("jobs", "slug,recruitcrm_id"),
  ]);
  return {
    byId: new Map((sl ?? []).map((s: any) => [s.recruitcrm_stage_id, s])),
    byLabel: new Map((sl ?? []).map((s: any) => [String(s.stage_name).toLowerCase(), s])),
    consName: new Map(cons.map((c: any) => [c.recruitcrm_id, c.name])),
    // job_id was never populated on candidate_stage_events — all 19,786 rows were null, so job
    // identity survived only through job_slug and every report had to join back through it.
    jobId: new Map(jobs.map((j: any) => [j.slug, j.recruitcrm_id])),
  };
}

// Fetch and upsert one candidate's stage history. Shared by both modes so the row mapping can
// never drift between them.
async function historyForCandidate(cand: any, maps: any) {
  const r = await crm(`/candidates/${cand.slug}/history`);
  if (!r.ok) return { ok: false, status: r.status, events: 0 };
  const raw: any[] = [];
  for (const e of (Array.isArray(r.json) ? r.json : [])) {
    const s = maps.byId.get(e.candidate_status_id) ?? maps.byLabel.get(String(e.candidate_status ?? "").toLowerCase());
    if (!s || !e.updated_on || !e.job_slug) continue;
    raw.push({
      candidate_id: cand.recruitcrm_id, candidate_slug: cand.slug, candidate_name: cand.name,
      job_slug: e.job_slug, job_id: maps.jobId.get(e.job_slug) ?? null, job_title: e.job_name ?? null,
      consultant_id: e.updated_by ?? null, consultant: maps.consName.get(e.updated_by) ?? null,
      stage_name: s.stage_name, stage_metric: s.stage_metric,
      event_timestamp: e.updated_on, event_date: String(e.updated_on).slice(0, 10),
    });
  }
  // Same ON CONFLICT hazard on the composite natural key.
  const rows = dedupeBy(raw, (x: any) => `${x.candidate_slug}|${x.job_slug}|${x.stage_metric}|${x.event_timestamp}`);
  if (rows.length) await db.from("candidate_stage_events").upsert(rows, { onConflict: "candidate_slug,job_slug,stage_metric,event_timestamp" }).throwOnError();

  // This endpoint returns the candidate's COMPLETE current history, so anything we hold for them
  // that is not in the response no longer exists upstream - an assignment removed, a stage move
  // undone, records merged. Without this the table is append-only and drifts permanently high: we
  // end up holding everything the API has ever said rather than what it says now. Measured against
  // RecruitCRM's own report before this landed: Jan +16, Jul +15, Aug +7, current week 0.
  //
  // Deleting rather than soft-deleting is safe here because every row is re-derivable from the API,
  // so a wrong prune self-heals on the next walk.
  let pruned = 0;
  try {
    const keep = rows.map((r: any) => ({ job_slug: r.job_slug, stage_metric: r.stage_metric, event_timestamp: r.event_timestamp }));
    const { data: pr } = await db.rpc("prune_candidate_events", { p_candidate_slug: cand.slug, p_keep: keep });
    pruned = pr ?? 0;
  } catch { /* leave the row set as-is; the next walk retries */ }

  return { ok: true, status: 200, events: rows.length, pruned };
}

async function syncHistory(maxCandidates: number) {
  const { data: st } = await db.from("sync_state").select("cursor,last_status").eq("entity", "history").maybeSingle();
  if (st?.last_status === "complete") return { entity: "history", complete: true, note: "already complete" };
  const maps = await historyMaps();
  let cursor = st?.cursor ? Number(st.cursor) : 0;

  const { data: cands } = await db.from("candidates").select("recruitcrm_id,slug,name").gt("recruitcrm_id", cursor).order("recruitcrm_id", { ascending: true }).limit(maxCandidates);
  if (!cands || cands.length === 0) {
    await db.from("sync_state").upsert({ entity: "history", last_run_at: new Date().toISOString(), last_status: "complete" }, { onConflict: "entity" });
    return { entity: "history", complete: true, processed: 0 };
  }
  let events = 0, processed = 0, skipped = 0, stopped: any = null;
  for (const cand of cands) {
    const res = await historyForCandidate(cand, maps);
    if (!res.ok) {
      if (res.status === 429) { stopped = 429; break; }   // back off; don't advance cursor
      skipped++; cursor = cand.recruitcrm_id; continue;   // 404/etc: skip candidate, advance
    }
    events += res.events; processed++; cursor = cand.recruitcrm_id; await sleep(50);
  }
  await db.from("sync_state").upsert({ entity: "history", cursor: String(cursor), last_run_at: new Date().toISOString(), last_status: stopped ? `stopped:${stopped}@${cursor}` : `cursor=${cursor} +${events}ev` }, { onConflict: "entity" });
  return { entity: "history", processed, skipped, events, cursor, stopped };
}

// The ongoing feed. A hiring-stage change bumps the candidate's updated_on in RecruitCRM, and the
// incremental sync keeps candidates.updated_date current, so "changed recently" is a reliable and
// very cheap filter — ~90 candidates a day against 16,600 total.
// offset lets a large catch-up be run in chunks — the walk is ordered by updated_date desc, so
// without it every run would redo the same first N candidates and never reach the tail.
// sleepMs paces against RecruitCRM's rate limit: 50ms (~4.6 req/s in practice) earns a 429, so the
// default is deliberately slower. Ordinary runs are ~90 candidates and finish well inside it.
async function markWalked(recruitcrmId: any) {
  try { await db.from("candidates").update({ history_walked_at: new Date().toISOString() }).eq("recruitcrm_id", recruitcrmId); } catch {}
}

// A work queue, not a time window.
//
// This previously took the N most-recently-updated candidates inside a one-day window, with offset
// pinned at 0. Two ways that lost events, both silent, and both one-directional — it could only
// ever under-count, never over-count:
//
//   * The cap sat below daily churn. 27/08/2026 touched 170 candidates against max_candidates=50.
//     Everything past the cap was never walked, and because the window only looked back one day it
//     was never revisited either.
//   * It read updated_date from OUR mirror, so it inherited the candidates poller's health. While
//     that poller was down (21/08–01/09/2026) a candidate whose row never refreshed never entered
//     the window at all, whatever they actually did in RecruitCRM.
//
// The funnel is the single source for every CV-send, interview and offer figure we publish, so both
// surfaced as numbers that were quietly and permanently low. A candidate is now due when we have
// never walked it, or when its record changed since our last walk. The backlog drains instead of
// falling off the tail, and a poller outage delays the walk rather than erasing it.
async function syncHistoryRecent(days: number, maxCandidates: number, offset = 0, sleepMs = 600) {
  const maps = await historyMaps();
  const { data: cands, error: qErr } = await db.rpc("candidates_due_for_history", { p_limit: maxCandidates });
  if (qErr) throw qErr;

  let events = 0, processed = 0, skipped = 0, pruned = 0, stopped: any = null;
  for (const cand of (cands ?? [])) {
    const res = await historyForCandidate(cand, maps);
    if (!res.ok) {
      if (res.status === 429) { stopped = 429; break; }   // back off; leave it due for the next run
      // 404 and friends: mark it walked anyway. Left due, a permanently-missing candidate sits at
      // the head of the queue and burns a slot on every run, forever.
      skipped++; await markWalked(cand.recruitcrm_id); continue;
    }
    events += res.events; processed++; pruned += (res as any).pruned ?? 0;
    await markWalked(cand.recruitcrm_id);
    await sleep(sleepMs);
  }

  const { count: queued } = await db.from("candidates")
    .select("recruitcrm_id", { count: "exact", head: true })
    .is("history_walked_at", null);
  const status = stopped ? `stopped:${stopped}@${processed}` : `cands=${processed} +${events}ev -${pruned}ev queue=${queued ?? 0}`;
  const row: any = { entity: "history_recent", last_run_at: new Date().toISOString(), last_status: status };
  if (!stopped) row.last_synced_at = new Date().toISOString();
  await db.from("sync_state").upsert(row, { onConflict: "entity" });
  return { entity: "history_recent", candidates_seen: (cands ?? []).length, processed, skipped, events, pruned, stopped, never_walked_remaining: queued ?? 0 };
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

    if (mode === "offlimit") return Response.json(await syncOffLimit());

    if (mode === "backfill_all") {
      if (entity !== "candidates") return Response.json({ error: "backfill_all currently supports entity=candidates only" }, { status: 400 });
      const maxP = parseInt(url.searchParams.get("max_pages") ?? "150", 10);
      const sp = url.searchParams.get("start_page");
      const fn = () => backfillCandidatesResumable(sp, maxP);
      // Deliberately NOT runBg. backfillCandidatesResumable maintains its own sync_state row, and
      // runBg would overwrite last_status with a JSON dump of the result - which breaks the
      // "already complete" check and makes the drain restart a full 518-page pass every few
      // minutes instead of stopping. Keep runBg's error handling, drop its success write.
      const guarded = async () => {
        try { await fn(); }
        catch (e) {
          try { await db.from("sync_state").update({ last_status: "error:" + String(e).slice(0, 200) }).eq("entity", "backfill:candidates"); } catch {}
        }
      };
      try { (globalThis as any).EdgeRuntime?.waitUntil(guarded()); }
      catch { return Response.json(await fn()); }
      return Response.json({ mode: "backfill_all", entity, status: "started (background)" }, { status: 202 });
    }

    // Notes have no sort parameter, so there is no cursor to follow — but the list is newest-first,
    // so re-walking the first few pages keeps the mirror current. Records sync_state so the feed is
    // health-monitored; a plain backfill deliberately does not.
    if (mode === "notes_recent") {
      const pages = parseInt(url.searchParams.get("max_pages") ?? "3", 10);
      const res = await backfillLoop("notes", 1, pages, "notes", mapNote, "notes");
      await db.from("sync_state").upsert({ entity: "notes", last_run_at: new Date().toISOString(),
        last_status: res.stopped ? `stopped:${res.stopped}` : `pages=${res.pages_processed} +${res.total_upserted}`,
        last_synced_at: new Date().toISOString() }, { onConflict: "entity" });
      return Response.json(res);
    }

    if (mode === "history_recent") {
      const days = parseInt(url.searchParams.get("days") ?? "2", 10);
      const maxC = parseInt(url.searchParams.get("max_candidates") ?? "120", 10);
      const offset = parseInt(url.searchParams.get("offset") ?? "0", 10);
      const sleepMs = parseInt(url.searchParams.get("sleep_ms") ?? "600", 10);
      return Response.json(await syncHistoryRecent(days, maxC, offset, sleepMs));
    }

    if (mode === "incremental") {
      const out: any = { mode: "incremental", results: [] };
      // One entity must never be able to abort the ones behind it. A single unmirrorable candidate
      // threw here on 21/08/2026 and took jobs and calls down with it for eleven days — silently,
      // because pg_cron records only the HTTP post, not the 500 that came back, and the entities
      // that never ran kept their last good sync_state row and so still looked merely "stale".
      // Isolate each step; record the failure against its own entity so sync_health() goes
      // critical on it (last_status outside the good set is an immediate critical), and leave
      // last_run_at untouched so the staleness clock keeps running too.
      const step = async (name: string, fn: () => Promise<any>) => {
        try { out.results.push(await fn()); }
        catch (e) {
          const msg = String(e).slice(0, 200);
          out.results.push({ entity: name, error: msg });
          try { await db.from("sync_state").update({ last_status: "error:" + msg }).eq("entity", name); } catch {}
        }
      };
      if (entity === "all" || entity === "consultants") await step("consultants", () => syncConsultants());
      if (entity === "all" || entity === "clients") await step("clients", () => incremental("clients", "companies", mapClient, "clients"));
      if (entity === "all" || entity === "candidates") await step("candidates", () => incremental("candidates", "candidates", mapCandidate, "candidates"));
      if (entity === "all" || entity === "jobs") await step("jobs", async () => { const [cb, sb] = await jobMaps(); return incremental("jobs", "jobs", mapJobFactory(cb, sb), "jobs"); });
      if (entity === "all" || entity === "calls") await step("calls", async () => { const cn = await consNameMap(); return incremental("calls", "call-logs", mapCallFactory(cn), "call_activity"); });
      if (entity === "all" || entity === "deals") await step("deals", () => incremental("deals", "deals", mapDeal, "deals"));
      return Response.json(out);
    }

    if (mode === "reconcile") {
      if (entity === "consultants") return Response.json(await reconcileConsultants());
      const fn = entity === "clients" ? () => reconcilePaged("clients", "companies", "clients")
               : entity === "candidates" ? () => reconcilePaged("candidates", "candidates", "candidates")
               : entity === "jobs" ? () => reconcilePaged("jobs", "jobs", "jobs")
               : entity === "deals" ? () => reconcileDeals() : null;
      if (!fn) return Response.json({ error: "reconcile needs entity=consultants|clients|candidates|jobs|deals" }, { status: 400 });
      try { (globalThis as any).EdgeRuntime?.waitUntil(runBg(`reconcile:${entity}`, fn)); } catch {}
      return Response.json({ mode: "reconcile", entity, status: "started (background)" }, { status: 202 });
    }

    const startPage = parseInt(url.searchParams.get("start_page") ?? "1", 10);
    const maxPages = parseInt(url.searchParams.get("max_pages") ?? "1", 10);
    if (entity === "consultants") return Response.json(await syncConsultants());
    if (entity === "clients") return Response.json(await backfillLoop("clients", startPage, maxPages, "companies", mapClient, "clients"));
    if (entity === "candidates") return Response.json(await backfillLoop("candidates", startPage, maxPages, "candidates", mapCandidate, "candidates"));
    if (entity === "jobs") { const [cb, sb] = await jobMaps(); return Response.json(await backfillLoop("jobs", startPage, maxPages, "jobs", mapJobFactory(cb, sb), "jobs")); }
    if (entity === "calls") { const cn = await consNameMap(); return Response.json(await backfillLoop("calls", startPage, maxPages, "call-logs", mapCallFactory(cn), "call_activity")); }
    if (entity === "deals") return Response.json(await backfillLoop("deals", startPage, maxPages, "deals", mapDeal, "deals"));
    if (entity === "notes") return Response.json(await backfillLoop("notes", startPage, maxPages, "notes", mapNote, "notes"));
    return Response.json({ error: "entity must be consultants|clients|candidates|jobs|calls|deals" }, { status: 400 });
  } catch (e) {
    return Response.json({ error: String(e) }, { status: 500 });
  }
});
