// octagon-mcp - remote MCP server for claude.ai. Read tools (get_dashboard,
// funnel_report) are open (aggregates, no PII). Write tools (update_hiring_stage,
// assign_candidate) are GATED behind OCTAGON_WRITE_KEY and do preview->confirm,
// optimistic concurrency, audit logging, and write-through mirror refresh.
// Connector URL: https://kzcmssldvtjnbwwunuwm.supabase.co/functions/v1/octagon-mcp
import { createClient } from "jsr:@supabase/supabase-js@2";
const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const TOKEN = (Deno.env.get("RECRUIT_CRM_API_TOKEN") ?? Deno.env.get("RECRUITCRM_API_TOKEN") ?? "").trim();
const BASE = "https://api.recruitcrm.io/v1";
const SERVER = { name: "octagon-analytics", version: "2.0.0" };

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

function writeGate(req: Request, args: any): { ok: boolean; reason?: string } {
  const key = Deno.env.get("OCTAGON_WRITE_KEY");
  if (!key) return { ok: false, reason: "Write-back is disabled: the server has no OCTAGON_WRITE_KEY set. An admin must set that Supabase secret to enable actions." };
  const provided = req.headers.get("x-octagon-key") || args?.auth_key;
  if (provided !== key) return { ok: false, reason: "Unauthorized: this connector is not configured with the write key, so actions are blocked." };
  return { ok: true };
}

const TOOLS = [
  { name: "get_dashboard", description: "Live Octagon recruitment dashboard (KPIs, 2026 funnel, per-consultant performance, deal pipeline). Aggregates only, no PII, no arguments. Call at the start of a conversation and for firm-wide overviews.", inputSchema: { type: "object", properties: {}, additionalProperties: false } },
  { name: "funnel_report", description: "Recruitment funnel + conversion ratios for a date window, optionally filtered to one consultant (partial name match) or team. Use for questions like 'how did Keelan do in Q2', 'the tech team last month', 'firm funnel this year'. Dates are ISO (YYYY-MM-DD); 'to' is exclusive. Defaults to 2026 year-to-date. Read-only.", inputSchema: { type: "object", properties: { from: { type: "string", description: "start date YYYY-MM-DD (inclusive)" }, to: { type: "string", description: "end date YYYY-MM-DD (exclusive)" }, consultant: { type: "string", description: "consultant name, partial match" }, team: { type: "string" } }, additionalProperties: false } },
  { name: "update_hiring_stage", description: "Move a candidate to a new hiring stage on a job in RecruitCRM. TWO-STEP AND EXPLICIT-ONLY: only use when the recruiter explicitly asks to change a stage. First call WITHOUT confirm to get a preview of current vs proposed stage; show it and get explicit approval; then call again with confirm=true and expected_status_id set to the current status_id from the preview. Requires the acting consultant's RecruitCRM user id (updated_by attribution). status_id from the pipeline: CV Sent=390955, Interview Request=381800, 1st Interview=381799, 2nd Interview=381801, Offered=381805, Placed=8. Set create_placement=true only when moving to Placed.", inputSchema: { type: "object", properties: { candidate_slug: { type: "string" }, job_slug: { type: "string" }, status_id: { type: "integer" }, consultant_recruitcrm_id: { type: "integer", description: "acting consultant's RecruitCRM user id" }, remark: { type: "string" }, create_placement: { type: "boolean" }, confirm: { type: "boolean", description: "false/omitted = preview only; true = apply" }, expected_status_id: { type: "integer", description: "current status_id from the preview; write refused if it no longer matches" }, auth_key: { type: "string" } }, required: ["candidate_slug", "job_slug", "status_id", "consultant_recruitcrm_id"], additionalProperties: false } },
  { name: "assign_candidate", description: "Assign a candidate to a job in RecruitCRM. EXPLICIT-ONLY and two-step: call without confirm for a preview, get approval, then confirm=true. Requires the acting consultant's RecruitCRM user id.", inputSchema: { type: "object", properties: { candidate_slug: { type: "string" }, job_slug: { type: "string" }, consultant_recruitcrm_id: { type: "integer" }, confirm: { type: "boolean" }, auth_key: { type: "string" } }, required: ["candidate_slug", "job_slug", "consultant_recruitcrm_id"], additionalProperties: false } },
];

const rpc = (id: any, result: any) => ({ jsonrpc: "2.0", id, result });
const rpcErr = (id: any, code: number, message: string) => ({ jsonrpc: "2.0", id, error: { code, message } });
const toolText = (o: any) => ({ content: [{ type: "text", text: JSON.stringify(o) }] });

async function callTool(name: string, args: any, req: Request) {
  if (name === "get_dashboard") { const { data, error } = await db.rpc("dashboard_json"); return toolText(error ? { error: error.message } : data); }
  if (name === "funnel_report") {
    const { data, error } = await db.rpc("funnel_report", { p_from: args?.from ?? "2026-01-01", p_to: args?.to ?? "2100-01-01", p_consultant: args?.consultant ?? null, p_team: args?.team ?? null });
    return toolText(error ? { error: error.message } : data);
  }
  if (name === "update_hiring_stage") {
    const g = writeGate(req, args); if (!g.ok) return toolText({ error: g.reason });
    const byId = await stageLookup();
    const proposed = byId.get(args.status_id);
    const cur = await currentStage(args.candidate_slug, args.job_slug);
    if (!args.confirm) return toolText({ mode: "preview", candidate_slug: args.candidate_slug, job_slug: args.job_slug, current_stage: cur, proposed_stage: { status_id: args.status_id, name: proposed?.stage_name ?? "(unknown id)" }, create_placement: !!args.create_placement, instruction: "Show this to the recruiter. To apply, call again with confirm=true and expected_status_id=" + (cur?.status_id ?? "null") + "." });
    if (args.expected_status_id != null && cur && cur.status_id !== args.expected_status_id) return toolText({ error: "conflict", message: "The candidate's stage changed to '" + cur.label + "' (id " + cur.status_id + ") since the preview. Re-preview before applying." });
    const r = await crm("POST", `/candidates/${args.candidate_slug}/hiring-stages/${args.job_slug}`, { status_id: args.status_id, remark: args.remark ?? null, updated_by: args.consultant_recruitcrm_id, create_placement: !!args.create_placement });
    if (!r.ok) return toolText({ error: "recruitcrm_error", status: r.status, detail: r.text?.slice(0, 200) });
    await audit({ actor: String(args.consultant_recruitcrm_id), action: "update_hiring_stage", entity: "candidate", entity_id: args.candidate_slug, before: cur, after: { status_id: args.status_id, name: proposed?.stage_name, job_slug: args.job_slug, create_placement: !!args.create_placement }, via: "claude" });
    const refreshed = await refreshCandidate(args.candidate_slug);
    return toolText({ mode: "applied", candidate_slug: args.candidate_slug, job_slug: args.job_slug, new_status_id: args.status_id, new_stage: proposed?.stage_name, mirror_events_refreshed: refreshed, note: "RecruitCRM updated and the mirror was refreshed immediately." });
  }
  if (name === "assign_candidate") {
    const g = writeGate(req, args); if (!g.ok) return toolText({ error: g.reason });
    if (!args.confirm) return toolText({ mode: "preview", action: "assign_candidate", candidate_slug: args.candidate_slug, job_slug: args.job_slug, instruction: "Show this to the recruiter. To apply, call again with confirm=true." });
    const r = await crm("POST", `/candidates/${args.candidate_slug}/assign?job_slug=${encodeURIComponent(args.job_slug)}&updated_by=${encodeURIComponent(String(args.consultant_recruitcrm_id))}`);
    if (!r.ok) return toolText({ error: "recruitcrm_error", status: r.status, detail: r.text?.slice(0, 200) });
    await audit({ actor: String(args.consultant_recruitcrm_id), action: "assign_candidate", entity: "candidate", entity_id: args.candidate_slug, before: null, after: { job_slug: args.job_slug }, via: "claude" });
    const refreshed = await refreshCandidate(args.candidate_slug);
    return toolText({ mode: "applied", candidate_slug: args.candidate_slug, job_slug: args.job_slug, mirror_events_refreshed: refreshed, note: "Candidate assigned in RecruitCRM and mirror refreshed." });
  }
  return null;
}

async function handle(m: any, req: Request): Promise<any> {
  const { id, method, params } = m ?? {};
  if (method === "initialize") return rpc(id, { protocolVersion: params?.protocolVersion || "2025-06-18", capabilities: { tools: {} }, serverInfo: SERVER });
  if (typeof method === "string" && method.startsWith("notifications/")) return null;
  if (method === "ping") return rpc(id, {});
  if (method === "tools/list") return rpc(id, { tools: TOOLS });
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
