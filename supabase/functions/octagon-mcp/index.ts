// octagon-mcp - remote MCP server for claude.ai.
//
// AUTH (per-user bearer tokens): EVERY tool call must present a valid token
// (Authorization: Bearer <t>, or x-octagon-token header, or auth_token arg).
// The token maps to a consultant via mcp_tokens; identity is derived server-side
// and can never be spoofed by a tool argument. can_write is per token.
//
// READ tools : get_dashboard, funnel_report, client_report, time_to_fill, cold_jobs,
//              placements_report, consultant_leaderboard, bd_report, find_candidate,
//              job_pipeline, stalled_report, my_day, match_candidates, call_activity
// WRITE tools: update_hiring_stage, assign_candidate, add_note  (require token.can_write;
//              two-step preview->confirm, optimistic concurrency, audit, write-through)
// PROMPTS    : dashboard, kpi, weekly_team_review, my_cold_roles, client_health, month_in_review, my_day, match_jd
//              job_kickoff, job_advert, job_boolean, job_inmail, client_pitch, job_shortlist  (new-job admin pack)
//
// Connector URL: https://kzcmssldvtjnbwwunuwm.supabase.co/functions/v1/octagon-mcp
import { createClient } from "jsr:@supabase/supabase-js@2";
const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const TOKEN = (Deno.env.get("RECRUIT_CRM_API_TOKEN") ?? Deno.env.get("RECRUITCRM_API_TOKEN") ?? "").trim();
const BASE = "https://api.recruitcrm.io/v1";
const SERVER = { name: "octagon-analytics", version: "3.8.0" };

async function crm(method: string, path: string, body?: any) {
  const res = await fetch(`${BASE}${path}`, { method, headers: { Authorization: `Bearer ${TOKEN}`, Accept: "application/json", "Content-Type": "application/json" }, body: body ? JSON.stringify(body) : undefined });
  const text = await res.text(); let json: any = null; try { json = JSON.parse(text); } catch {}
  return { ok: res.ok, status: res.status, json, text };
}
async function stageLookup() {
  const { data } = await db.from("stage_lookup").select("recruitcrm_stage_id,stage_metric,stage_name");
  return new Map((data ?? []).map((s: any) => [s.recruitcrm_stage_id, s]));
}
async function currentStage(candidate: string, job: string) {
  const r = await crm("GET", `/candidates/${candidate}/history`);
  if (!r.ok || !Array.isArray(r.json)) return null;
  const forJob = r.json.filter((e: any) => e.job_slug === job && e.updated_on);
  if (!forJob.length) return null;
  forJob.sort((a: any, b: any) => Date.parse(b.updated_on) - Date.parse(a.updated_on));
  return { status_id: forJob[0].candidate_status_id, label: forJob[0].candidate_status, updated_on: forJob[0].updated_on };
}
async function refreshCandidate(candidate: string) {
  const [{ data: cand }, byId, { data: cons }] = await Promise.all([
    db.from("candidates").select("recruitcrm_id,name").eq("slug", candidate).maybeSingle(),
    stageLookup(),
    db.from("consultants").select("recruitcrm_id,name"),
  ]);
  const consName = new Map((cons ?? []).map((c: any) => [c.recruitcrm_id, c.name]));
  const r = await crm("GET", `/candidates/${candidate}/history`);
  if (!r.ok || !Array.isArray(r.json)) return 0;
  const rows: any[] = [];
  for (const e of r.json) {
    const s = byId.get(e.candidate_status_id);
    if (!s || !e.updated_on || !e.job_slug) continue;
    rows.push({ candidate_id: cand?.recruitcrm_id ?? null, candidate_slug: candidate, candidate_name: cand?.name ?? null, job_slug: e.job_slug, job_title: e.job_name ?? null, consultant_id: e.updated_by ?? null, consultant: consName.get(e.updated_by) ?? null, stage_name: s.stage_name, stage_metric: s.stage_metric, event_timestamp: e.updated_on, event_date: String(e.updated_on).slice(0, 10) });
  }
  if (rows.length) await db.from("candidate_stage_events").upsert(rows, { onConflict: "candidate_slug,job_slug,stage_metric,event_timestamp" });
  return rows.length;
}
async function audit(entry: any) { try { await db.from("audit_log").insert(entry); } catch (_e) {} }
// Fire-and-forget usage telemetry (no PII args) — feeds admin_digest()/the Slack bot.
function logCall(actorId: any, tool: string, ok = true) {
  db.from("mcp_call_log").insert({ consultant_recruitcrm_id: actorId ?? null, tool, ok }).then(() => {}, () => {});
}

// ---- Auth ------------------------------------------------------------------
async function sha256hex(s: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, "0")).join("");
}
async function authenticate(req: Request, args: any): Promise<{ ok: boolean; actor?: any; reason?: string }> {
  const hdr = req.headers.get("authorization") || "";
  const bearer = hdr.toLowerCase().startsWith("bearer ") ? hdr.slice(7).trim() : "";
  const token = (bearer || req.headers.get("x-octagon-token") || args?.auth_token || "").trim();
  if (!token) return { ok: false, reason: "Authentication required. Configure this connector with your Octagon access token (an admin mints one via mint_mcp_token)." };
  const hash = await sha256hex(token);
  const { data } = await db.from("mcp_tokens").select("consultant_recruitcrm_id,label,can_write").eq("token_hash", hash).eq("active", true).maybeSingle();
  if (!data) return { ok: false, reason: "Invalid or revoked token." };
  db.from("mcp_tokens").update({ last_used_at: new Date().toISOString() }).eq("token_hash", hash).then(() => {}, () => {});
  return { ok: true, actor: { id: data.consultant_recruitcrm_id, label: data.label, can_write: data.can_write } };
}

const AUTH_ARG = { auth_token: { type: "string", description: "Octagon access token (only needed if the connector isn't sending it as a bearer header)." } };
const TOOLS = [
  { name: "get_dashboard", description: "Live Octagon recruitment dashboard (KPIs, 2026 funnel, per-consultant performance, deal pipeline, sync health). Aggregates only, no PII. Call at the start of a conversation and for firm-wide overviews.", inputSchema: { type: "object", properties: { ...AUTH_ARG }, additionalProperties: false } },
  { name: "funnel_report", description: "Recruitment funnel + conversion ratios for a date window, optionally filtered to one consultant (partial name match) or team. Use for 'how did Keelan do in Q2', 'the tech team last month', 'firm funnel this year'. Dates ISO (YYYY-MM-DD); 'to' is exclusive. Defaults to 2026 YTD. Read-only.", inputSchema: { type: "object", properties: { from: { type: "string" }, to: { type: "string" }, consultant: { type: "string" }, team: { type: "string" }, ...AUTH_ARG }, additionalProperties: false } },
  { name: "client_report", description: "Per-client (account) activity for a window: CVs sent, first interviews, placements, open/total jobs, and CV->placed rate, ranked by volume. Use for 'how is <client> doing', 'our busiest accounts this year'. ~40% of jobs have no resolved client (archived companies) and are omitted. Read-only.", inputSchema: { type: "object", properties: { from: { type: "string" }, to: { type: "string" }, client: { type: "string", description: "client name, partial match" }, limit: { type: "integer" }, ...AUTH_ARG }, additionalProperties: false } },
  { name: "time_to_fill", description: "Time-to-fill in days (job created -> first placement) for jobs placed in the window: firm avg/median/min/max plus a per-consultant breakdown. Owner-attributed. Use for 'how long are we taking to fill roles', 'time to fill by consultant'. Read-only.", inputSchema: { type: "object", properties: { from: { type: "string" }, to: { type: "string" }, consultant: { type: "string" }, team: { type: "string" }, ...AUTH_ARG }, additionalProperties: false } },
  { name: "cold_jobs", description: "OPEN roles with no candidate activity in the last N days (default 14), oldest first. Job titles/clients only, no candidate PII. Use for 'which of my roles have gone cold', 'stale open jobs'. Read-only.", inputSchema: { type: "object", properties: { days: { type: "integer", description: "staleness threshold in days (default 14)" }, consultant: { type: "string" }, limit: { type: "integer" }, ...AUTH_ARG }, additionalProperties: false } },
  { name: "placements_report", description: "Placements in a window (event-stream 'placed' count; the placements table is empty so there are no fees) plus Won-deal revenue, broken down by consultant and client. Use for 'placements this quarter', 'who placed the most'. Read-only.", inputSchema: { type: "object", properties: { from: { type: "string" }, to: { type: "string" }, consultant: { type: "string" }, team: { type: "string" }, ...AUTH_ARG }, additionalProperties: false } },
  { name: "consultant_leaderboard", description: "Consultants ranked by a chosen metric ('placed' default, or 'cv_sent' / 'first_interview') for a window, with CV->placed rate. Owner-attributed. Use for 'top performers', 'leaderboard by CVs'. Read-only.", inputSchema: { type: "object", properties: { from: { type: "string" }, to: { type: "string" }, metric: { type: "string", enum: ["placed", "cv_sent", "first_interview"] }, limit: { type: "integer" }, ...AUTH_ARG }, additionalProperties: false } },
  { name: "bd_report", description: "Business-development / client funnel: how many companies sit at each 'Company Status' (Prospect, Engaged, Client, Passive, Blocklisted, Do-not-contact), from RecruitCRM company custom fields. Use for 'how many prospects vs clients', 'BD pipeline', 'account status breakdown'. NOTE: RecruitCRM has no 'Lead' status, and 'pitched candidates'/'job order form complete' are not tracked. Read-only, no arguments.", inputSchema: { type: "object", properties: { ...AUTH_ARG }, additionalProperties: false } },
  { name: "find_candidate", description: "Look up a candidate by name -> their candidate_slug and current hiring stage on each job. Use this FIRST to resolve who someone is before acting on them (e.g. before update_hiring_stage). Returns candidate names (PII). Read-only.", inputSchema: { type: "object", properties: { name: { type: "string", description: "candidate name, partial match" }, limit: { type: "integer" }, ...AUTH_ARG }, required: ["name"], additionalProperties: false } },
  { name: "job_pipeline", description: "For a job (by title or slug), the candidates in play and their current stage, plus the in-play count. Use for 'what's happening on the Bosch role', 'who's shortlisted for X', or to find a job_slug before acting. Returns candidate names (PII). Read-only.", inputSchema: { type: "object", properties: { job: { type: "string", description: "job title (partial) or exact job_slug" }, limit: { type: "integer" }, ...AUTH_ARG }, required: ["job"], additionalProperties: false } },
  { name: "stalled_report", description: "What needs attention firm-wide: aging offers (offer out 5-60d with no response) and stalled candidates (active stage, no movement 10-60d) on OPEN roles, owner-attributed, most-overdue first. Use for 'what's slipping', 'what should we chase'. Returns candidate names (PII). Read-only.", inputSchema: { type: "object", properties: { stall_days: { type: "integer" }, offer_days: { type: "integer" }, max_days: { type: "integer" }, ...AUTH_ARG }, additionalProperties: false } },
  { name: "my_day", description: "One consultant's attention list on OPEN roles: aging offers, stalled candidates, active-in-play count, cold open roles, and placements in the last 7 days. With NO consultant argument it scopes to YOU (your token). Pass consultant to view someone else. Use for 'what's my day', 'what needs my attention', 'how's Keelan's desk'. Returns candidate names (PII). Read-only.", inputSchema: { type: "object", properties: { consultant: { type: "string", description: "consultant name; omit to use your own identity" }, ...AUTH_ARG }, additionalProperties: false } },
  { name: "match_candidates", description: "Find candidates in the CRM whose skills match a set of skills, ranked by number of matches, with the matched skills and their recent roles for explaining fit. Use for JD->candidate matching: extract the key skills from a job description yourself, then call this with them. Optionally filter by location. Only candidates with skill text populated (~73%) are considered. Returns candidate names (PII). Read-only.", inputSchema: { type: "object", properties: { skills: { type: "array", items: { type: "string" }, description: "skills/keywords extracted from the job description" }, location: { type: "string", description: "optional city or country filter" }, limit: { type: "integer" }, ...AUTH_ARG }, required: ["skills"], additionalProperties: false } },
  { name: "call_activity", description: "Telephony activity (calls logged in RecruitCRM via Devyce) for a date window: total calls, connect rate, talk-time in minutes, outgoing/incoming, a per-consultant leaderboard, and a breakdown by call category (e.g. 'Contact - Prospect (BD)', 'Candidate - Job Pitch / Qualifying'). Attributed to the CALLER. Use for 'call activity this week', 'who's making the most calls', 'talk time by consultant', 'BD call volume'. Dates ISO; defaults to 2026 YTD. Read-only.", inputSchema: { type: "object", properties: { from: { type: "string" }, to: { type: "string" }, consultant: { type: "string" }, team: { type: "string" }, ...AUTH_ARG }, additionalProperties: false } },
  { name: "update_hiring_stage", description: "Move a candidate to a new hiring stage on a job in RecruitCRM. WRITE, two-step, EXPLICIT-ONLY: first call WITHOUT confirm for a preview (current vs proposed); show it and get explicit approval; then call again confirm=true with expected_status_id = the current status_id from the preview. The acting consultant is taken from your token (not an argument). status_id: CV Sent=390955, Interview Request=381800, 1st Interview=381799, 2nd Interview=381801, Offered=381805, Placed=8. Set create_placement=true only when moving to Placed.", inputSchema: { type: "object", properties: { candidate_slug: { type: "string" }, job_slug: { type: "string" }, status_id: { type: "integer" }, remark: { type: "string" }, create_placement: { type: "boolean" }, confirm: { type: "boolean", description: "false/omitted = preview only; true = apply" }, expected_status_id: { type: "integer", description: "current status_id from the preview; write refused if it changed" }, ...AUTH_ARG }, required: ["candidate_slug", "job_slug", "status_id"], additionalProperties: false } },
  { name: "assign_candidate", description: "Assign a candidate to a job in RecruitCRM. WRITE, two-step, EXPLICIT-ONLY: call without confirm for a preview, get approval, then confirm=true. The acting consultant is taken from your token.", inputSchema: { type: "object", properties: { candidate_slug: { type: "string" }, job_slug: { type: "string" }, confirm: { type: "boolean" }, ...AUTH_ARG }, required: ["candidate_slug", "job_slug"], additionalProperties: false } },
  { name: "add_note", description: "Add a note to a candidate or job in RecruitCRM. WRITE, two-step, EXPLICIT-ONLY: call without confirm for a preview, get approval, then confirm=true. The note is attributed to the acting consultant (your token). target_type is 'candidate' or 'job'; target_slug is that record's slug (use find_candidate / job_pipeline to get it).", inputSchema: { type: "object", properties: { target_type: { type: "string", enum: ["candidate", "job"] }, target_slug: { type: "string" }, note: { type: "string", description: "the note text" }, confirm: { type: "boolean" }, ...AUTH_ARG }, required: ["target_type", "target_slug", "note"], additionalProperties: false } },
];

// ---- Prompts ---------------------------------------------------------------
const PROMPTS = [
  { name: "dashboard", description: "Full live dashboard: KPIs, 2026 funnel, per-consultant performance and the deal pipeline (with sync-health check).", arguments: [] },
  { name: "kpi", description: "Headline KPI numbers only — placements, open jobs, pipeline value and firm totals, concise.", arguments: [] },
  { name: "weekly_team_review", description: "Week-over-week firm funnel + leaderboard, with call-outs.", arguments: [] },
  { name: "my_cold_roles", description: "Open roles going cold for a named consultant.", arguments: [{ name: "consultant", description: "consultant name", required: true }] },
  { name: "client_health", description: "Account activity, open roles and conversion for one client this year.", arguments: [{ name: "client", description: "client / company name", required: true }] },
  { name: "month_in_review", description: "One-month summary: funnel, placements and revenue.", arguments: [{ name: "month", description: "YYYY-MM (defaults to current month)", required: false }] },
  { name: "my_day", description: "Your personal attention list for today (offers, stalled, cold roles).", arguments: [] },
  { name: "match_jd", description: "Paste a job description -> ranked matching candidates with explained fit.", arguments: [] },
  { name: "job_kickoff", description: "New-job admin pack: run Octagon's vacancy checklist for a role — research/pitch, top-5 CRM shortlist, then adverts/Boolean/InMail on request.", arguments: [{ name: "job", description: "job title (partial) or slug; you can also just paste the spec", required: false }] },
  { name: "job_advert", description: "Write the LinkedIn advert and the website advert for a job (from the pasted job spec).", arguments: [{ name: "job", description: "job title or slug for context", required: false }] },
  { name: "job_boolean", description: "Build Boolean search strings for a job — one for job boards, one for LinkedIn.", arguments: [{ name: "job", description: "job title or slug for context", required: false }] },
  { name: "job_inmail", description: "Write a short, personalised LinkedIn InMail to approach a candidate about a job.", arguments: [{ name: "job", description: "job title or slug for context", required: false }] },
  { name: "client_pitch", description: "Create the phone pitch to represent the client for a role — what they do, why it's exciting, process & next steps.", arguments: [{ name: "job", description: "job title or slug for context", required: false }] },
  { name: "job_shortlist", description: "Top-5 CRM candidates for a job (via skill match), with explained fit and the chasing order — call these first.", arguments: [{ name: "job", description: "job title or slug for context", required: false }] },
];
function monthWindow(month?: string): { from: string; to: string; label: string } {
  if (month && /^\d{4}-\d{2}$/.test(month)) {
    const [y, m] = month.split("-").map(Number);
    const from = `${month}-01`;
    const to = (m === 12) ? `${y + 1}-01-01` : `${y}-${String(m + 1).padStart(2, "0")}-01`;
    return { from, to, label: month };
  }
  const now = new Date();
  const y = now.getUTCFullYear(), m = now.getUTCMonth() + 1;
  const from = `${y}-${String(m).padStart(2, "0")}-01`;
  const to = (m === 12) ? `${y + 1}-01-01` : `${y}-${String(m + 1).padStart(2, "0")}-01`;
  return { from, to, label: `${y}-${String(m).padStart(2, "0")}` };
}
function getPrompt(name: string, args: any): any | null {
  const msg = (text: string) => ({ messages: [{ role: "user", content: { type: "text", text } }] });
  if (name === "dashboard") {
    return { description: "Live dashboard", ...msg("Call get_dashboard. FIRST inspect the payload's health object: if health.overall is not 'ok', lead with a clear banner naming the stale or failing feeds (each health.entities[].entity with its .reason) and warn that the figures below may be stale; if it is 'ok', a one-line 'sync healthy' note is enough. Then present the full dashboard: the KPI cards, the 2026 funnel, per-consultant performance (attributed by job owner), and the deal pipeline. Keep it plain — compact tables, no heavy styling.") };
  }
  if (name === "kpi") {
    return { description: "Headline KPIs", ...msg("Call get_dashboard. Glance at health.overall first — if it is not 'ok', add a single-line warning naming the affected feeds (health.entities[].entity) before the numbers. Then present ONLY the headline KPIs, concisely: placements (2026 and all-time), open jobs, open pipeline value, Won revenue, and the firm totals (candidates, clients, jobs, active consultants). Do NOT include the funnel, the per-consultant breakdown, or the deal-pipeline table — just the top-line numbers.") };
  }
  if (name === "weekly_team_review") {
    return { description: "Weekly team review", ...msg("Give me this week's team review. Call funnel_report for the last 7 days and again for the 7 days before that, and compare week-over-week. Then call consultant_leaderboard ranked by 'placed' for the last 7 days. Summarise concisely: what moved in the funnel, who is ahead, and flag any consultant whose CV->1st-interview rate dropped versus the prior week.") };
  }
  if (name === "my_cold_roles") {
    const c = args?.consultant ?? "";
    return { description: "Cold roles", ...msg(`Call cold_jobs with consultant='${c}' and days=14. List the open roles that have gone cold, oldest activity first, with how many days since last activity, and suggest which to chase first.`) };
  }
  if (name === "client_health") {
    const cl = args?.client ?? "";
    return { description: "Client health", ...msg(`Call client_report filtered to client='${cl}' for 2026 year-to-date. Summarise that account: CVs sent, first interviews, placements, open vs total jobs, and the CV->placed rate. Note if the account looks under- or over-served.`) };
  }
  if (name === "month_in_review") {
    const w = monthWindow(args?.month);
    return { description: `Month in review ${w.label}`, ...msg(`Call funnel_report and placements_report for from='${w.from}' to='${w.to}' (${w.label}). Give a concise summary: CVs sent, interviews, placements, key conversion rates, and Won revenue. Call out anything notable versus a typical month.`) };
  }
  if (name === "my_day") {
    return { description: "My day", ...msg("Call my_day with no consultant argument (so it uses my own identity). Present my attention list: aging offers and stalled candidates first (most overdue), then my cold open roles and anything I placed in the last 7 days. Be concise and action-oriented.") };
  }
  if (name === "match_jd") {
    return { description: "Match a job description to candidates", ...msg("The user has pasted (or will paste) a job description. Extract the key hard skills, tools, and must-have requirements from it as a concise list. Call match_candidates with that skills list (add a location filter only if the JD requires one). Then present the top candidates RANKED by fit, and for each explain WHY — cite which required skills they matched and their recent roles. Flag anyone strong on skills but missing a must-have. If few candidates have skills on file, say so.") };
  }
  const jobArg = (args?.job ?? "").toString().trim();
  const jobCtx = jobArg ? `The job is '${jobArg}' — call job_pipeline with job='${jobArg}' to pull up its title and client for context. ` : "If a job hasn't been named, ask which role this is for. ";
  if (name === "job_kickoff") {
    return { description: "New-job admin pack", ...msg(jobCtx + "A new job has come in — run Octagon's vacancy checklist and build the admin pack, conversationally (don't dump everything at once). Steps: (1) Confirm the job and ask the recruiter to paste the full job spec plus any client background if not already provided — you need this to write good content. (2) Research & pitch: summarise what the client does, why the role is exciting, and the application process/next steps the consultant can use on a call. (3) Shortlist: extract the key skills from the spec, call match_candidates, present the top 5 CRM candidates with why each fits, and tell the consultant to CALL these first. (4) Then offer to generate any of: LinkedIn advert, website advert, LinkedIn InMail, Boolean (job boards), Boolean (LinkedIn) — each is also its own command. Candidate names are internal (PII); never invent a salary.") };
  }
  if (name === "job_advert") {
    return { description: "Job adverts", ...msg(jobCtx + "Write recruitment adverts for the role. Ask the recruiter to paste the job spec if they haven't. Produce TWO versions: (1) a LinkedIn advert — punchy, employer voice, hook + role + must-haves + what's on offer + a clear call to action + a few relevant hashtags; (2) a website advert — a little longer, with headings (The Company / The Role / What You'll Need / What's on Offer / How to Apply). Use inclusive, neutral language and never invent a salary — only state pay if the recruiter gave it.") };
  }
  if (name === "job_boolean") {
    return { description: "Boolean searches", ...msg(jobCtx + "Build Boolean search strings for the role. Use the pasted spec (ask for it, or the key skills, if missing). Extract must-have skills, likely job titles and their synonyms. Produce TWO strings: (1) a job-board Boolean (portable across CV databases) and (2) a LinkedIn Boolean (LinkedIn-friendly title/skill phrasing). Group synonyms with OR in parentheses, combine requirements with AND, exclude noise with NOT. Briefly explain your choices so the consultant can tweak.") };
  }
  if (name === "job_inmail") {
    return { description: "LinkedIn InMail", ...msg(jobCtx + "Write a LinkedIn InMail to approach a candidate about the role. Ask for the spec / ideal-candidate profile if needed. Keep it under ~120 words, personalised, leading with why THEM specifically, one sentence on the opportunity, and a low-friction call to action (open to a quick chat?). Warm and human, not salesy. Also give a shorter follow-up variant for a second touch.") };
  }
  if (name === "client_pitch") {
    return { description: "Client phone pitch", ...msg(jobCtx + "Create a phone pitch the consultant can use to represent the client for this role. Ask for the spec / client background if needed. Cover: what the company does (positioning, size, why it's a good place to work), why THIS role is exciting (impact, growth, scope), and the application process & next steps. Lay it out as natural talking points for a call, then add 2-3 likely candidate objections with suggested responses.") };
  }
  if (name === "job_shortlist") {
    return { description: "Top-5 CRM shortlist", ...msg(jobCtx + "Shortlist the top candidates on the CRM for this role. Extract the key hard skills / must-haves from the spec (ask for it if missing). Call match_candidates with those skills (add a location filter only if the role requires one). Present the TOP 5 ranked by fit; for each, explain why — which required skills matched and their recent roles — and flag anyone strong but missing a must-have. Tell the consultant to CALL these first, and remind them of Octagon's chasing order: call → voicemail → text → email → call from a different number → LinkedIn connect + message. Candidate names are internal (PII).") };
  }
  return null;
}

const rpc = (id: any, result: any) => ({ jsonrpc: "2.0", id, result });
const rpcErr = (id: any, code: number, message: string) => ({ jsonrpc: "2.0", id, error: { code, message } });
const toolText = (o: any) => ({ content: [{ type: "text", text: JSON.stringify(o) }] });

async function callTool(name: string, args: any, req: Request) {
  // Every tool requires a valid token.
  const auth = await authenticate(req, args);
  if (!auth.ok) return toolText({ error: auth.reason });
  const actor = auth.actor;
  logCall(actor.id, name);

  if (name === "get_dashboard") { const { data, error } = await db.rpc("dashboard_json"); return toolText(error ? { error: error.message } : data); }
  if (name === "funnel_report") {
    const { data, error } = await db.rpc("funnel_report", { p_from: args?.from ?? "2026-01-01", p_to: args?.to ?? "2100-01-01", p_consultant: args?.consultant ?? null, p_team: args?.team ?? null });
    return toolText(error ? { error: error.message } : data);
  }
  if (name === "client_report") {
    const { data, error } = await db.rpc("client_report", { p_from: args?.from ?? "2026-01-01", p_to: args?.to ?? "2100-01-01", p_client: args?.client ?? null, p_limit: args?.limit ?? 20 });
    return toolText(error ? { error: error.message } : data);
  }
  if (name === "time_to_fill") {
    const { data, error } = await db.rpc("time_to_fill", { p_from: args?.from ?? "2026-01-01", p_to: args?.to ?? "2100-01-01", p_consultant: args?.consultant ?? null, p_team: args?.team ?? null });
    return toolText(error ? { error: error.message } : data);
  }
  if (name === "cold_jobs") {
    const { data, error } = await db.rpc("cold_jobs", { p_days: args?.days ?? 14, p_consultant: args?.consultant ?? null, p_limit: args?.limit ?? 50 });
    return toolText(error ? { error: error.message } : data);
  }
  if (name === "placements_report") {
    const { data, error } = await db.rpc("placements_report", { p_from: args?.from ?? "2026-01-01", p_to: args?.to ?? "2100-01-01", p_consultant: args?.consultant ?? null, p_team: args?.team ?? null });
    return toolText(error ? { error: error.message } : data);
  }
  if (name === "consultant_leaderboard") {
    const { data, error } = await db.rpc("consultant_leaderboard", { p_from: args?.from ?? "2026-01-01", p_to: args?.to ?? "2100-01-01", p_metric: args?.metric ?? "placed", p_limit: args?.limit ?? 20 });
    return toolText(error ? { error: error.message } : data);
  }
  if (name === "bd_report") { const { data, error } = await db.rpc("bd_report"); return toolText(error ? { error: error.message } : data); }
  if (name === "find_candidate") { const { data, error } = await db.rpc("find_candidate", { p_name: args?.name ?? null, p_limit: args?.limit ?? 10 }); return toolText(error ? { error: error.message } : data); }
  if (name === "job_pipeline") { const { data, error } = await db.rpc("job_pipeline", { p_job: args?.job ?? null, p_limit: args?.limit ?? 50 }); return toolText(error ? { error: error.message } : data); }
  if (name === "stalled_report") { const { data, error } = await db.rpc("stalled_report", { p_stall_days: args?.stall_days ?? 10, p_offer_days: args?.offer_days ?? 5, p_max_days: args?.max_days ?? 60 }); return toolText(error ? { error: error.message } : data); }
  if (name === "my_day") { const { data, error } = await db.rpc("my_day", { p_consultant_id: args?.consultant ? null : actor.id, p_consultant: args?.consultant ?? null }); return toolText(error ? { error: error.message } : data); }
  if (name === "match_candidates") { const { data, error } = await db.rpc("match_candidates", { p_skills: Array.isArray(args?.skills) ? args.skills : [], p_location: args?.location ?? null, p_limit: args?.limit ?? 20 }); return toolText(error ? { error: error.message } : data); }
  if (name === "call_activity") { const { data, error } = await db.rpc("call_activity_report", { p_from: args?.from ?? "2026-01-01", p_to: args?.to ?? "2100-01-01", p_consultant: args?.consultant ?? null, p_team: args?.team ?? null }); return toolText(error ? { error: error.message } : data); }
  if (name === "update_hiring_stage") {
    if (!actor.can_write) return toolText({ error: "Your token is read-only. Hiring-stage changes require a write-enabled token (an admin sets can_write)." });
    const byId = await stageLookup();
    const proposed = byId.get(args.status_id);
    const cur = await currentStage(args.candidate_slug, args.job_slug);
    if (!args.confirm) return toolText({ mode: "preview", candidate_slug: args.candidate_slug, job_slug: args.job_slug, current_stage: cur, proposed_stage: { status_id: args.status_id, name: proposed?.stage_name ?? "(unknown id)" }, create_placement: !!args.create_placement, acting_as: actor.id, instruction: "Show this to the recruiter. To apply, call again with confirm=true and expected_status_id=" + (cur?.status_id ?? "null") + "." });
    if (args.expected_status_id != null && cur && cur.status_id !== args.expected_status_id) return toolText({ error: "conflict", message: "The candidate's stage changed to '" + cur.label + "' (id " + cur.status_id + ") since the preview. Re-preview before applying." });
    const r = await crm("POST", `/candidates/${args.candidate_slug}/hiring-stages/${args.job_slug}`, { status_id: args.status_id, remark: args.remark ?? null, updated_by: actor.id, create_placement: !!args.create_placement });
    if (!r.ok) return toolText({ error: "recruitcrm_error", status: r.status, detail: r.text?.slice(0, 200) });
    await audit({ actor: String(actor.id), action: "update_hiring_stage", entity: "candidate", entity_id: args.candidate_slug, before: cur, after: { status_id: args.status_id, name: proposed?.stage_name, job_slug: args.job_slug, create_placement: !!args.create_placement }, via: "claude" });
    const refreshed = await refreshCandidate(args.candidate_slug);
    return toolText({ mode: "applied", candidate_slug: args.candidate_slug, job_slug: args.job_slug, new_status_id: args.status_id, new_stage: proposed?.stage_name, mirror_events_refreshed: refreshed, note: "RecruitCRM updated and the mirror was refreshed immediately." });
  }
  if (name === "assign_candidate") {
    if (!actor.can_write) return toolText({ error: "Your token is read-only. Assigning candidates requires a write-enabled token (an admin sets can_write)." });
    if (!args.confirm) return toolText({ mode: "preview", action: "assign_candidate", candidate_slug: args.candidate_slug, job_slug: args.job_slug, acting_as: actor.id, instruction: "Show this to the recruiter. To apply, call again with confirm=true." });
    const r = await crm("POST", `/candidates/${args.candidate_slug}/assign?job_slug=${encodeURIComponent(args.job_slug)}&updated_by=${encodeURIComponent(String(actor.id))}`);
    if (!r.ok) return toolText({ error: "recruitcrm_error", status: r.status, detail: r.text?.slice(0, 200) });
    await audit({ actor: String(actor.id), action: "assign_candidate", entity: "candidate", entity_id: args.candidate_slug, before: null, after: { job_slug: args.job_slug }, via: "claude" });
    const refreshed = await refreshCandidate(args.candidate_slug);
    return toolText({ mode: "applied", candidate_slug: args.candidate_slug, job_slug: args.job_slug, mirror_events_refreshed: refreshed, note: "Candidate assigned in RecruitCRM and mirror refreshed." });
  }
  if (name === "add_note") {
    if (!actor.can_write) return toolText({ error: "Your token is read-only. Adding notes requires a write-enabled token (an admin sets can_write)." });
    const rt = args.target_type === "job" ? "job" : "candidate";
    if (!args.confirm) return toolText({ mode: "preview", action: "add_note", target_type: rt, target_slug: args.target_slug, note_preview: String(args.note ?? "").slice(0, 300), acting_as: actor.id, instruction: "Show this to the recruiter. To apply, call again with confirm=true." });
    const body: any = { description: args.note, related_to: args.target_slug, related_to_type: rt, updated_by: actor.id };
    if (rt === "candidate") body.associated_candidates = [args.target_slug]; else body.associated_jobs = [args.target_slug];
    const r = await crm("POST", `/notes`, body);
    if (!r.ok) return toolText({ error: "recruitcrm_error", status: r.status, detail: r.text?.slice(0, 300) });
    await audit({ actor: String(actor.id), action: "add_note", entity: rt, entity_id: args.target_slug, before: null, after: { note: String(args.note ?? "").slice(0, 500) }, via: "claude" });
    return toolText({ mode: "applied", target_type: rt, target_slug: args.target_slug, note: "Note added in RecruitCRM, attributed to your user id." });
  }
  return null;
}

async function handle(m: any, req: Request): Promise<any> {
  const { id, method, params } = m ?? {};
  if (method === "initialize") return rpc(id, { protocolVersion: params?.protocolVersion || "2025-06-18", capabilities: { tools: {}, prompts: {} }, serverInfo: SERVER });
  if (typeof method === "string" && method.startsWith("notifications/")) return null;
  if (method === "ping") return rpc(id, {});
  if (method === "tools/list") return rpc(id, { tools: TOOLS });
  if (method === "prompts/list") return rpc(id, { prompts: PROMPTS });
  if (method === "prompts/get") {
    const p = getPrompt(params?.name, params?.arguments ?? {});
    if (!p) return rpcErr(id, -32602, "Unknown prompt: " + params?.name);
    return rpc(id, p);
  }
  if (method === "tools/call") {
    const out = await callTool(params?.name, params?.arguments ?? {}, req);
    if (out === null) return rpcErr(id, -32602, "Unknown tool: " + params?.name);
    return rpc(id, out);
  }
  if (id === undefined || id === null) return null;
  return rpcErr(id, -32601, "Method not found: " + method);
}

Deno.serve(async (req) => {
  const headers: Record<string, string> = { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "*", "Access-Control-Allow-Methods": "POST, GET, OPTIONS" };
  if (req.method === "OPTIONS") return new Response(null, { headers });
  if (req.method === "GET") return new Response(JSON.stringify({ name: SERVER.name, version: SERVER.version, transport: "streamable-http" }), { headers });
  let msg: any; try { msg = await req.json(); } catch { return new Response(JSON.stringify(rpcErr(null, -32700, "Parse error")), { headers }); }
  if (Array.isArray(msg)) { const out = (await Promise.all(msg.map((x) => handle(x, req)))).filter((x) => x !== null); return new Response(out.length ? JSON.stringify(out) : "", { status: out.length ? 200 : 202, headers }); }
  const res = await handle(msg, req);
  if (res === null) return new Response("", { status: 202, headers });
  return new Response(JSON.stringify(res), { headers });
});
