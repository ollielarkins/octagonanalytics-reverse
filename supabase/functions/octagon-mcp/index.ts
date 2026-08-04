// octagon-mcp - remote MCP server for claude.ai.
//
// AUTH (per-user bearer tokens): EVERY tool call must present a valid token
// (Authorization: Bearer <t>, or x-octagon-token header, or auth_token arg).
// The token maps to a consultant via mcp_tokens; identity is derived server-side
// and can never be spoofed by a tool argument. can_write is per token.
//
// READ tools : get_dashboard, funnel_report, client_report, time_to_fill,
//              cold_jobs, placements_report, consultant_leaderboard
// WRITE tools: update_hiring_stage, assign_candidate  (require token.can_write;
//              two-step preview->confirm, optimistic concurrency, audit, write-through)
// PROMPTS    : weekly_team_review, my_cold_roles, client_health, month_in_review
//
// Connector URL: https://kzcmssldvtjnbwwunuwm.supabase.co/functions/v1/octagon-mcp
import { createClient } from "jsr:@supabase/supabase-js@2";
const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const TOKEN = (Deno.env.get("RECRUIT_CRM_API_TOKEN") ?? Deno.env.get("RECRUITCRM_API_TOKEN") ?? "").trim();
const BASE = "https://api.recruitcrm.io/v1";
const SERVER = { name: "octagon-analytics", version: "3.1.0" };

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
  { name: "update_hiring_stage", description: "Move a candidate to a new hiring stage on a job in RecruitCRM. WRITE, two-step, EXPLICIT-ONLY: first call WITHOUT confirm for a preview (current vs proposed); show it and get explicit approval; then call again confirm=true with expected_status_id = the current status_id from the preview. The acting consultant is taken from your token (not an argument). status_id: CV Sent=390955, Interview Request=381800, 1st Interview=381799, 2nd Interview=381801, Offered=381805, Placed=8. Set create_placement=true only when moving to Placed.", inputSchema: { type: "object", properties: { candidate_slug: { type: "string" }, job_slug: { type: "string" }, status_id: { type: "integer" }, remark: { type: "string" }, create_placement: { type: "boolean" }, confirm: { type: "boolean", description: "false/omitted = preview only; true = apply" }, expected_status_id: { type: "integer", description: "current status_id from the preview; write refused if it changed" }, ...AUTH_ARG }, required: ["candidate_slug", "job_slug", "status_id"], additionalProperties: false } },
  { name: "assign_candidate", description: "Assign a candidate to a job in RecruitCRM. WRITE, two-step, EXPLICIT-ONLY: call without confirm for a preview, get approval, then confirm=true. The acting consultant is taken from your token.", inputSchema: { type: "object", properties: { candidate_slug: { type: "string" }, job_slug: { type: "string" }, confirm: { type: "boolean" }, ...AUTH_ARG }, required: ["candidate_slug", "job_slug"], additionalProperties: false } },
];

// ---- Prompts ---------------------------------------------------------------
const PROMPTS = [
  { name: "weekly_team_review", description: "Week-over-week firm funnel + leaderboard, with call-outs.", arguments: [] },
  { name: "my_cold_roles", description: "Open roles going cold for a named consultant.", arguments: [{ name: "consultant", description: "consultant name", required: true }] },
  { name: "client_health", description: "Account activity, open roles and conversion for one client this year.", arguments: [{ name: "client", description: "client / company name", required: true }] },
  { name: "month_in_review", description: "One-month summary: funnel, placements and revenue.", arguments: [{ name: "month", description: "YYYY-MM (defaults to current month)", required: false }] },
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
