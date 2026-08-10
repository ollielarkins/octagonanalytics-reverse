// octagon-mcp - remote MCP server for claude.ai.
//
// AUTH (per-user bearer tokens): EVERY tool call must present a valid token
// (Authorization: Bearer <t>, or x-octagon-token header, or auth_token arg).
// The token maps to a consultant via mcp_tokens; identity is derived server-side
// and can never be spoofed by a tool argument. can_write is per token.
//
// READ tools : get_dashboard, funnel_report, client_report, time_to_fill, cold_jobs,
//              placements_report, consultant_leaderboard, bd_report, find_candidate,
//              job_pipeline, stalled_report, my_day, match_candidates, call_activity, weekly_kpis, billing
// WRITE tools: update_hiring_stage, assign_candidate, add_note  (require token.can_write;
//              two-step preview->confirm, optimistic concurrency, audit, write-through)
// PROMPTS    : dashboard, kpi, weekly_team_review, my_cold_roles, client_health, month_in_review, my_day, match_jd
//              job_kickoff, job_advert, job_boolean, job_inmail, client_pitch, job_shortlist  (new-job admin pack)
//              candidate_intake, candidate_summary, candidate_thankyou, interview_prep  (candidate lifecycle)
//              weekly_kpis  (this-week actuals vs targets scorecard), billing (quarterly billing vs target),
//              day_plan  (personalised daily plan on Octagon's standard structure)
//              client_update, pipeline_chase  (client comms) ; bd_pitch, bd_targets, spec_pitch  (BD pack)
//
// Connector URL: https://kzcmssldvtjnbwwunuwm.supabase.co/functions/v1/octagon-mcp
import { createClient } from "jsr:@supabase/supabase-js@2";
const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const TOKEN = (Deno.env.get("RECRUIT_CRM_API_TOKEN") ?? Deno.env.get("RECRUITCRM_API_TOKEN") ?? "").trim();
const BASE = "https://api.recruitcrm.io/v1";
const SERVER = { name: "octagon-analytics", version: "3.25.0" };

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
  const { data } = await db.from("mcp_tokens").select("consultant_recruitcrm_id,label,can_write,is_admin").eq("token_hash", hash).eq("active", true).maybeSingle();
  if (!data) return { ok: false, reason: "Invalid or revoked token." };
  db.from("mcp_tokens").update({ last_used_at: new Date().toISOString() }).eq("token_hash", hash).then(() => {}, () => {});
  return { ok: true, actor: { id: data.consultant_recruitcrm_id, label: data.label, can_write: data.can_write, is_admin: !!data.is_admin } };
}

const AUTH_ARG = { auth_token: { type: "string", description: "Octagon access token (only needed if the connector isn't sending it as a bearer header)." } };

// ---- MCP Apps (SEP-1865) inline dashboard widget ------------------------------------------------
const MCP_APP_MIME = "text/html;profile=mcp-app";
const DASH_UI = "ui://octagon/dashboard";
// Self-contained widget: talks to the host over postMessage JSON-RPC, renders get_dashboard's
// structuredContent inline. No external requests (sandboxed iframe).
const DASHBOARD_WIDGET_HTML = `<!doctype html><html><head><meta charset="utf-8"><style>
:root{--bg:#fff;--fg:#111;--mut:#666;--card:#f6f6f7;--line:#e6e6e8;--accent:#111;--good:#137333;--bad:#b00020}
@media (prefers-color-scheme:dark){:root{--bg:#191919;--fg:#f2f2f2;--mut:#9a9a9a;--card:#242424;--line:#333;--accent:#e8e8e8}}
:root[data-theme=dark]{--bg:#191919;--fg:#f2f2f2;--mut:#9a9a9a;--card:#242424;--line:#333;--accent:#e8e8e8}
:root[data-theme=light]{--bg:#fff;--fg:#111;--mut:#666;--card:#f6f6f7;--line:#e6e6e8;--accent:#111}
*{box-sizing:border-box}body{margin:0;font-family:system-ui,-apple-system,sans-serif;background:var(--bg);color:var(--fg);padding:16px;font-size:14px}
h1{font-size:1.05rem;margin:0 0 4px}.sub{margin-bottom:12px}
.pill{display:inline-block;padding:2px 9px;border-radius:99px;font-size:.7rem;font-weight:600}
.ok{background:rgba(19,115,51,.16);color:var(--good)}.stale{background:rgba(176,0,32,.16);color:var(--bad)}
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(116px,1fr));gap:8px;margin-bottom:8px}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:10px 12px}
.card .v{font-size:1.3rem;font-weight:700;font-variant-numeric:tabular-nums}.card .l{color:var(--mut);font-size:.68rem;margin-top:2px}
h2{font-size:.74rem;margin:18px 0 6px;text-transform:uppercase;letter-spacing:.05em;color:var(--mut)}
.bar{display:flex;align-items:center;gap:8px;margin:3px 0}.bar .lab{width:118px;color:var(--mut);font-size:.75rem}
.bar .track{flex:1;background:var(--card);border-radius:6px;overflow:hidden;height:16px}.bar .fill{height:100%;background:var(--accent);opacity:.85}
.bar .n{width:48px;text-align:right;font-variant-numeric:tabular-nums;font-size:.78rem}
table{width:100%;border-collapse:collapse;font-size:.78rem}th,td{text-align:left;padding:4px 6px;border-bottom:1px solid var(--line)}
td.num,th.num{text-align:right;font-variant-numeric:tabular-nums}
.kpi{display:flex;justify-content:space-between;padding:4px 0;border-bottom:1px solid var(--line);font-size:.82rem}
.behind{color:var(--bad);font-weight:700}.met{color:var(--good);font-weight:600}
.foot{color:var(--mut);font-size:.7rem;margin-top:5px;line-height:1.4}
.banner{background:rgba(176,0,32,.12);color:var(--bad);border:1px solid rgba(176,0,32,.3);border-radius:8px;padding:8px 10px;font-size:.78rem;margin-bottom:12px}
</style></head><body><div id="app"><div class="sub">Loading dashboard…</div></div><script>
var GBP=function(n){return n==null?'—':'£'+Math.round(Number(n)).toLocaleString('en-GB')};
var N=function(n){return n==null?'—':Number(n).toLocaleString('en-GB')};
function esc(s){return String(s==null?'':s).replace(/[&<>]/g,function(c){return{'&':'&amp;','<':'&lt;','>':'&gt;'}[c]})}
// House date format is DD/MM/YYYY; the RPCs hand back ISO.
function D(s){var m=/^(\d{4})-(\d{2})-(\d{2})/.exec(String(s==null?'':s));return m?m[3]+'/'+m[2]+'/'+m[1]:esc(s)}
function cards(cd){return '<div class="cards">'+cd.map(function(c){return '<div class="card"><div class="v">'+c[1]+'</div><div class="l">'+c[0]+'</div></div>'}).join('')+'</div>'}
function syncline(h){var ok=(h.overall==='ok'),o='<div class="sub"><span class="pill '+(ok?'ok':'stale')+'">'+(ok?'sync healthy':'sync issue')+'</span></div>';
if(!ok){var fe=(h.entities||[]).filter(function(e){return e.status!=='ok'}).map(function(e){return esc(e.entity)+' ('+esc(e.reason)+')'}).join(', ');o+='<div class="banner">Sync not OK — figures may be stale: '+(fe||'unknown')+'</div>'}return o}
function bars(st){var mx=Math.max.apply(null,st.map(function(s){return s[1]||0}).concat([1]));
return st.map(function(s){var w=Math.round(100*(s[1]||0)/mx);return '<div class="bar"><span class="lab">'+s[0]+'</span><span class="track"><span class="fill" style="width:'+w+'%"></span></span><span class="n">'+N(s[1]||0)+'</span></div>'}).join('')}
// Recruiter view: their own desk first (week vs target, billing, what needs chasing today), firm
// totals demoted to one line. Deliberately NO team breakdown and no firm deal-pipeline table.
function meView(d,v){var o='',h=d.health||{},k=d.kpis||{},w=v.my_weekly||{},b=v.my_billing||{},md=v.my_day||{},y=v.my_2026||{};
o+='<h1>Your desk'+(v.name?' — '+esc(v.name):'')+'</h1>'+syncline(h);
o+=cards([['Placed 2026',N(y.placed)],['Won this quarter',GBP(b.won_qtr)],['Open pipeline',GBP(b.pipeline_open)],['Active in play',N(md.active_in_play)],['Aging offers',N(md.aging_offers?md.aging_offers.length:null)],['Cold open roles',N(md.cold_open_roles)]]);
var rw=[['CV sends','cv_sent'],['Interview requests','interview_request'],['Interviews','first_interview'],['BD calls','bd_calls'],['Client calls','client_calls']];
if(v.my_weekly){o+='<h2>Your week vs target'+(v.week_start?' — from '+D(v.week_start):'')+'</h2>'+rw.map(function(r){var m=w[r[1]]||{},a=m.actual||0,t=m.target,cl=(t!=null&&a<t)?'behind':'met';return '<div class="kpi"><span>'+r[0]+'</span><span class="'+cl+'">'+a+(t!=null?' / '+t:'')+'</span></div>'}).join('')+'<div class="foot">BD/client calls count categorised Devyce calls only, so can undercount.'+(v.my_calls&&v.my_calls.logged?' You logged '+N(v.my_calls.logged)+' call'+(v.my_calls.logged===1?'':'s')+' this week and tagged '+N(v.my_calls.tagged)+' ('+Math.round(100*v.my_calls.tagged/v.my_calls.logged)+'%) — untagged calls cannot count toward these targets.':'')+'</div>'}
if(v.my_billing){var tg=b.quarterly_target,wq=b.won_qtr||0,pc=(tg?Math.round(100*wq/tg):null),sh=(tg!=null?tg-wq:null);
o+='<h2>Your billing'+(v.quarter_start?' — quarter from '+D(v.quarter_start):'')+'</h2>'
+'<div class="kpi"><span>Won (billed)</span><span class="'+(tg!=null&&wq<tg?'behind':'met')+'">'+GBP(wq)+(tg!=null?' / '+GBP(tg):'')+(pc!=null?' ('+pc+'%)':'')+'</span></div>'
+(sh!=null&&sh>0?'<div class="kpi"><span>Still to bill</span><span class="behind">'+GBP(sh)+'</span></div>':'')
+'<div class="kpi"><span>Open pipeline</span><span>'+GBP(b.pipeline_open)+'</span></div>'}
var ao=md.aging_offers||[],sl=md.stalled||[];
if(ao.length){o+='<h2>Aging offers — chase today</h2><table><tr><th>Candidate</th><th>Role</th><th class="num">Days</th></tr>'+ao.map(function(x){return '<tr><td>'+esc(x.candidate)+'</td><td>'+esc(x.job_title)+'</td><td class="num behind">'+N(x.days)+'</td></tr>'}).join('')+'</table>'}
if(sl.length){var top=sl.slice(0,10);o+='<h2>Stalled candidates'+(sl.length>10?' — top 10 of '+sl.length:'')+'</h2><table><tr><th>Candidate</th><th>Role</th><th>Stage</th><th class="num">Days</th></tr>'+top.map(function(x){return '<tr><td>'+esc(x.candidate)+'</td><td>'+esc(x.job_title)+'</td><td>'+esc(x.stage)+'</td><td class="num">'+N(x.days)+'</td></tr>'}).join('')+'</table>'}
if(v.my_day&&!ao.length&&!sl.length)o+='<h2>Needs attention</h2><div class="foot">Nothing aging or stalled on your open roles. '+N(md.cold_open_roles)+' cold role(s), '+N(md.placed_last_7d)+' placed in the last 7 days.</div>';
if(v.my_2026){o+='<h2>Your 2026 funnel</h2>'+bars([['Shortlist',y.shortlist],['CV Sent',y.cv_sent],['Interview Request',y.interview_request],['1st Interview',y.first_interview],['Offered',y.offered],['Placed',y.placed]])+'<div class="foot">2nd/3rd interview are not broken out per consultant here — ask for your funnel_report.</div>'}
o+='<h2>Firm — 2026</h2><div class="foot">'+N(k.cv_2026)+' CV sent · '+N(k.placed_2026)+' placed · '+N(k.open_jobs)+' open jobs · '+GBP(k.open_pipeline)+' open pipeline</div>';
return o}
// Admin view: firm first, then the whole-team breakdown.
function firmView(d){var h=d.health||{},k=d.kpis||{},f=d.funnel||{},pl=d.pipeline||[],o='';
o+='<h1>Octagon Recruitment Dashboard</h1>'+syncline(h);
o+=cards([['Placed 2026',N(k.placed_2026)],['Placed all-time',N(k.placed_all)],['Open jobs',N(k.open_jobs)],['Open pipeline',GBP(k.open_pipeline)],['Won',GBP(k.won)],['Candidates in pipeline',N(k.candidates_in_pipeline!=null?k.candidates_in_pipeline:k.candidates)],['Candidates on CRM',N(k.candidates_total)],['Clients',N(k.clients)],['Consultants',N(k.consultants)]]);
if(k.jobs_no_client)o+='<div class="foot">'+N(k.jobs_no_client)+' of '+N(k.jobs)+' jobs have no resolved client and are excluded from client/account reporting.</div>';
o+='<h2>2026 Funnel</h2>'+bars([['Shortlist',f.shortlist],['CV Sent',f.cv_sent],['Interview Request',f.interview_request],['1st Interview',f.first_interview],['2nd Interview',f.second_interview],['3rd Interview',f.third_interview],['Offered',f.offered],['Placed',f.placed]])
+'<div class="foot">Shortlist is partially adopted — fewer shortlist events than CV sends, so don\'t read it as a top-of-funnel denominator.</div>';
if(pl.length){o+='<h2>Deal Pipeline</h2><table><tr><th>Stage</th><th class="num">Deals</th><th class="num">Value</th></tr>'+pl.map(function(p){return '<tr><td>'+esc(p.stage)+'</td><td class="num">'+N(p.deals)+'</td><td class="num">'+GBP(p.value)+'</td></tr>'}).join('')+'</table>'}
if(d.consultants&&d.consultants.length){o+='<h2>Team — by job owner</h2><table><tr><th>Consultant</th><th class="num">CV</th><th class="num">1st Int</th><th class="num">Placed</th></tr>'+d.consultants.map(function(c){return '<tr><td>'+esc(c.name)+'</td><td class="num">'+N(c.cv_sent)+'</td><td class="num">'+N(c.first_interview)+'</td><td class="num">'+N(c.placed)+'</td></tr>'}).join('')+'</table>'}
return o}
function render(d){if(!d)return;var v=d.viewer||{};
// A resolved consultant gets the desk view; admins and unresolved tokens get the firm view.
document.getElementById('app').innerHTML=(v.name&&!v.is_admin)?meView(d,v):firmView(d)}
window.addEventListener('message',function(ev){var m=ev.data;if(!m||m.jsonrpc!=='2.0')return;
if(m.id===1&&m.result&&m.result.hostContext&&m.result.hostContext.theme)document.documentElement.setAttribute('data-theme',m.result.hostContext.theme);
if(m.method==='ui/notifications/tool-result'&&m.params&&m.params.structuredContent)render(m.params.structuredContent)});
window.parent.postMessage({jsonrpc:'2.0',id:1,method:'ui/initialize',params:{capabilities:{},clientInfo:{name:'octagon-dashboard',version:'1.0'},protocolVersion:'2026-01-26',appCapabilities:{availableDisplayModes:['inline','fullscreen']}}},'*');
</script></body></html>`;

// Shared scorecard widget for weekly_kpis + billing (branches on the payload shape).
const SCORE_UI = "ui://octagon/scorecard";
const SCORECARD_WIDGET_HTML = `<!doctype html><html><head><meta charset="utf-8"><style>
:root{--bg:#fff;--fg:#111;--mut:#666;--card:#f6f6f7;--line:#e6e6e8;--good:#137333;--bad:#b00020}
@media (prefers-color-scheme:dark){:root{--bg:#191919;--fg:#f2f2f2;--mut:#9a9a9a;--card:#242424;--line:#333}}
:root[data-theme=dark]{--bg:#191919;--fg:#f2f2f2;--mut:#9a9a9a;--card:#242424;--line:#333}
:root[data-theme=light]{--bg:#fff;--fg:#111;--mut:#666;--card:#f6f6f7;--line:#e6e6e8}
*{box-sizing:border-box}body{margin:0;font-family:system-ui,-apple-system,sans-serif;background:var(--bg);color:var(--fg);padding:16px;font-size:14px}
h1{font-size:1.02rem;margin:0 0 2px}.sub{color:var(--mut);font-size:.72rem;margin-bottom:12px}
table{width:100%;border-collapse:collapse;font-size:.78rem}th,td{text-align:left;padding:5px 6px;border-bottom:1px solid var(--line)}
td.num,th.num{text-align:right;font-variant-numeric:tabular-nums}.behind{color:var(--bad);font-weight:700}.met{color:var(--good);font-weight:600}
</style></head><body><div id="app"><div class="sub">Loading…</div></div><script>
var GBP=function(n){return n==null?'—':'£'+Math.round(Number(n)).toLocaleString('en-GB')};
function esc(s){return String(s==null?'':s).replace(/[&<>]/g,function(c){return{'&':'&amp;','<':'&lt;','>':'&gt;'}[c]})}
// House date format is DD/MM/YYYY; the RPCs hand back ISO.
function D(s){var m=/^(\d{4})-(\d{2})-(\d{2})/.exec(String(s==null?'':s));return m?m[3]+'/'+m[2]+'/'+m[1]:esc(s)}
function render(d){if(!d)return;var o='',cs=d.consultants||[];
if(d.week_start){o+='<h1>Weekly KPIs</h1><div class="sub">week from '+D(d.week_start)+(d.has_targets?'':' · targets not loaded')+' · BD/client calls count categorised Devyce calls only</div>';
var m=[['CV','cv_sent'],['Int req','interview_request'],['Int','first_interview'],['BD','bd_calls'],['Client','client_calls'],['Placed','placed']];
o+='<table><tr><th>Consultant</th>'+m.map(function(x){return '<th class="num">'+x[0]+'</th>'}).join('')+'</tr>'+cs.map(function(c){return '<tr><td>'+esc(c.name)+'</td>'+m.map(function(x){var v=c[x[1]]||{},a=v.actual||0,t=v.target,cl=(t!=null&&a<t)?'behind':(t!=null?'met':'');return '<td class="num '+cl+'">'+a+(t!=null?'/'+t:'')+'</td>'}).join('')+'</tr>'}).join('')+'</table>';}
else if(d.quarter_start){o+='<h1>Quarterly Billing</h1><div class="sub">quarter from '+D(d.quarter_start)+' · Won = billed (Deal → Won); pipeline is the forward indicator</div>';
o+='<table><tr><th>Consultant</th><th class="num">Target</th><th class="num">Won QTD</th><th class="num">Pipeline</th><th class="num">% target</th></tr>'+cs.map(function(c){var tg=c.quarterly_target,wq=c.won_qtr||0,p=(tg?Math.round(100*wq/tg):null);return '<tr><td>'+esc(c.name)+'</td><td class="num">'+(tg!=null?GBP(tg):'—')+'</td><td class="num">'+GBP(wq)+'</td><td class="num">'+GBP(c.pipeline_open)+'</td><td class="num">'+(p!=null?p+'%':'—')+'</td></tr>'}).join('')+'</table>';}
if(!cs.length)o+='<div class="sub">No data for you yet.</div>';
document.getElementById('app').innerHTML=o||'<div class="sub">No data.</div>';}
window.addEventListener('message',function(ev){var m=ev.data;if(!m||m.jsonrpc!=='2.0')return;
if(m.id===1&&m.result&&m.result.hostContext&&m.result.hostContext.theme)document.documentElement.setAttribute('data-theme',m.result.hostContext.theme);
if(m.method==='ui/notifications/tool-result'&&m.params&&m.params.structuredContent)render(m.params.structuredContent)});
window.parent.postMessage({jsonrpc:'2.0',id:1,method:'ui/initialize',params:{capabilities:{},clientInfo:{name:'octagon-scorecard',version:'1.0'},protocolVersion:'2026-01-26',appCapabilities:{availableDisplayModes:['inline','fullscreen']}}},'*');
</script></body></html>`;

const TOOLS = [
  { name: "get_dashboard", description: "Live Octagon dashboard, scoped to who is asking. A recruiter gets their OWN desk: week vs weekly targets, quarterly billing vs target, their 2026 funnel, and their attention list (aging offers, stalled candidates, cold open roles) — this part names candidates, so it is internal-only, not client-facing. Admins get firm KPIs, the 2026 funnel, deal pipeline and the whole-team breakdown. Always includes sync health. Call at the start of a conversation and for overviews. Renders as an inline dashboard widget.", inputSchema: { type: "object", properties: { ...AUTH_ARG }, additionalProperties: false }, _meta: { ui: { resourceUri: DASH_UI, visibility: ["model", "app"] } } },
  { name: "funnel_report", description: "Recruitment funnel + conversion ratios for a date window, optionally filtered to one consultant (partial name match) or team. Use for 'how did Keelan do in Q2', 'the tech team last month', 'firm funnel this year'. Dates ISO (YYYY-MM-DD); 'to' is exclusive. Defaults to 2026 YTD. Read-only.", inputSchema: { type: "object", properties: { from: { type: "string" }, to: { type: "string" }, consultant: { type: "string" }, team: { type: "string" }, ...AUTH_ARG }, additionalProperties: false } },
  { name: "client_report", description: "Per-client (account) activity for a window: CVs sent, first interviews, placements, open/total jobs, and CV->placed rate, ranked by volume. Use for 'how is <client> doing', 'our busiest accounts this year'. Covers ~99.8% of jobs; a handful with no company on the record are omitted. Read-only.", inputSchema: { type: "object", properties: { from: { type: "string" }, to: { type: "string" }, client: { type: "string", description: "client name, partial match" }, limit: { type: "integer" }, ...AUTH_ARG }, additionalProperties: false } },
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
  { name: "weekly_kpis", description: "This-week (from Monday) actuals vs weekly targets (CV sends, interview requests, interviews, BD/client calls, placements). Scoped: a recruiter sees their own row, admins/managers see the whole team. Renders as an inline scorecard widget. Read-only, no arguments.", inputSchema: { type: "object", properties: { ...AUTH_ARG }, additionalProperties: false }, _meta: { ui: { resourceUri: SCORE_UI, visibility: ["model", "app"] } } },
  { name: "billing", description: "Quarter-to-date billing vs quarterly target (owner-attributed): Won revenue this quarter (the billing figure), all-time Won, and in-play pipeline as the forward indicator. Scoped: a recruiter sees their own row, admins the whole team. Renders as an inline scorecard widget. Read-only, no arguments.", inputSchema: { type: "object", properties: { ...AUTH_ARG }, additionalProperties: false }, _meta: { ui: { resourceUri: SCORE_UI, visibility: ["model", "app"] } } },
  { name: "update_hiring_stage", description: "Move a candidate to a new hiring stage on a job in RecruitCRM. WRITE, two-step, EXPLICIT-ONLY: first call WITHOUT confirm for a preview (current vs proposed); show it and get explicit approval; then call again confirm=true with expected_status_id = the current status_id from the preview. The acting consultant is taken from your token (not an argument). status_id: CV Sent=390955, Interview Request=381800, 1st Interview=381799, 2nd Interview=381801, Offered=381805, Placed=8. Set create_placement=true only when moving to Placed.", inputSchema: { type: "object", properties: { candidate_slug: { type: "string" }, job_slug: { type: "string" }, status_id: { type: "integer" }, remark: { type: "string" }, create_placement: { type: "boolean" }, confirm: { type: "boolean", description: "false/omitted = preview only; true = apply" }, expected_status_id: { type: "integer", description: "current status_id from the preview; write refused if it changed" }, ...AUTH_ARG }, required: ["candidate_slug", "job_slug", "status_id"], additionalProperties: false } },
  { name: "assign_candidate", description: "Assign a candidate to a job in RecruitCRM. WRITE, two-step, EXPLICIT-ONLY: call without confirm for a preview, get approval, then confirm=true. The acting consultant is taken from your token.", inputSchema: { type: "object", properties: { candidate_slug: { type: "string" }, job_slug: { type: "string" }, confirm: { type: "boolean" }, ...AUTH_ARG }, required: ["candidate_slug", "job_slug"], additionalProperties: false } },
  { name: "add_note", description: "Add a note to a candidate or job in RecruitCRM. WRITE, two-step, EXPLICIT-ONLY: call without confirm for a preview, get approval, then confirm=true. The note is attributed to the acting consultant (your token). target_type is 'candidate' or 'job'; target_slug is that record's slug (use find_candidate / job_pipeline to get it).", inputSchema: { type: "object", properties: { target_type: { type: "string", enum: ["candidate", "job"] }, target_slug: { type: "string" }, note: { type: "string", description: "the note text" }, confirm: { type: "boolean" }, ...AUTH_ARG }, required: ["target_type", "target_slug", "note"], additionalProperties: false } },
];

// ---- Prompts ---------------------------------------------------------------
const PROMPTS = [
  { name: "dashboard", description: "Full live dashboard: KPIs, 2026 funnel, per-consultant performance and the deal pipeline (with sync-health check).", arguments: [] },
  { name: "kpi", description: "Headline KPI numbers only — placements, open jobs, pipeline value and firm totals, concise.", arguments: [] },
  { name: "weekly_kpis", description: "This-week KPI scorecard: each recruiter's actuals vs weekly targets, flagging who's behind.", arguments: [] },
  { name: "billing", description: "Quarterly billing scorecard: each recruiter's target vs Won-so-far and open pipeline value.", arguments: [] },
  { name: "day_plan", description: "Build a consultant's day plan for today on Octagon's standard structure, slotting in their live priorities.", arguments: [{ name: "consultant", description: "consultant name; omit for your own day", required: false }] },
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
  { name: "candidate_intake", description: "Turn a candidate call (paste notes / Devyce transcript) into Octagon's intake template, and flag what's missing + what to ask next time.", arguments: [{ name: "candidate", description: "candidate name to resolve (optional)", required: false }] },
  { name: "candidate_summary", description: "Client-facing candidate summary that sells the candidate for a role (from intake notes / CV).", arguments: [{ name: "candidate", description: "candidate name to resolve (optional)", required: false }] },
  { name: "candidate_thankyou", description: "Warm post-call thank-you email to a candidate — recap the fit, share the spec & company, set next steps.", arguments: [{ name: "candidate", description: "candidate name to resolve (optional)", required: false }] },
  { name: "interview_prep", description: "Interview-preparation email for a candidate — time/place, dress, how to prepare, questions to ask.", arguments: [{ name: "candidate", description: "candidate name to resolve (optional)", required: false }] },
  { name: "client_update", description: "Draft a weekly client update email: what we've done, push/pull, and what we could do to find more.", arguments: [{ name: "client", description: "client / company name", required: false }] },
  { name: "pipeline_chase", description: "Find candidate sends stalled with a client and draft chase-ups for feedback/next steps.", arguments: [{ name: "job", description: "job title or slug to focus on (optional)", required: false }] },
  { name: "bd_pitch", description: "BD cold-call pitch for a target contact — opener, value prop, the ask, and objection handling.", arguments: [{ name: "company", description: "target company / contact", required: false }] },
  { name: "bd_targets", description: "Identify and prioritise key BD targets from the client/BD funnel.", arguments: [] },
  { name: "spec_pitch", description: "Speculative pitch of a strong candidate to prospective clients (anonymised teaser + email).", arguments: [{ name: "candidate", description: "candidate name (optional)", required: false }] },
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
  if (name === "weekly_kpis") {
    return { description: "Weekly KPI scorecard", ...msg("Call the weekly_kpis tool. Present each recruiter's THIS-WEEK actuals vs their weekly target for CV sends, interview requests, first interviews, BD calls, client calls and placements as a compact table, and clearly flag who is BEHIND on any metric and by how much. Note that bd_calls/client_calls only count categorised Devyce calls (so they can undercount). If has_targets is false, say targets haven't been loaded yet and show actuals only. Be concise and action-oriented — this is the Monday/daily nudge, so end with the 2-3 people/metrics that most need attention this week.") };
  }
  if (name === "billing") {
    return { description: "Quarterly billing scorecard", ...msg("Call the billing tool. Present each recruiter's quarterly target vs their Won-this-quarter (the billing figure) and their open pipeline value, as a compact table showing % to target and a 'pipeline vs remaining gap' coverage read. Flag who has already hit/exceeded target, who is on track (enough pipeline to cover the gap), and who is behind on both Won and pipeline. Recruiters without a loaded target (e.g. Will Drake) — note target TBC and just show their Won/pipeline.") };
  }
  if (name === "day_plan") {
    const who = (args?.consultant ?? "").toString().trim();
    const scope = who ? `for ${who} (pass consultant='${who}' to the tools)` : "for yourself (call the tools with no consultant argument so they use your own token identity)";
    return { description: "Day plan", ...msg(`Build today's day plan ${scope}. First gather live priorities: call my_day (aging offers, stalled candidates, cold open roles, recent placements) and weekly_kpis (where they're behind target this week); optionally cold_jobs and stalled_report for more detail. Then lay out the day on Octagon's standard structure, slotting the REAL priorities into each block:\n- 08:00-09:00 Call shortlists & start candidate search\n- 09:00-10:00 Review plan/watchdogs/meetings; call new candidates; set up searches for focus jobs\n- 10:00-11:00 Candidate time — call shortlists, prep/arrange interviews, LinkedIn\n- 11:00-12:00 Business Development — call job & client lists; follow up pitched candidates\n- 12:00-13:00 Lunch\n- 13:00-14:00 Candidate time (shortlists + new candidates); watchdogs\n- 14:00-16:00 Search & call candidates for the focus job\n- 16:00-16:30 Admin — adverts, pitch candidates, leads, update deals\n- 16:30+ Chase the strong candidates on your shortlists\nPut the most urgent items (aging offers, stalled candidates on open roles) into the morning candidate blocks, BD prospects into the BD hour, and NAME the specific roles/candidates to action. Where they're behind on a weekly KPI, add a concrete nudge (e.g. 'at 3/10 CV sends — aim to send X today'). Keep it concrete; candidate names are internal (PII).`) };
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
  const candArg = (args?.candidate ?? "").toString().trim();
  const candCtx = candArg ? `The candidate is '${candArg}' — call find_candidate with name='${candArg}' to resolve them and get context. ` : "If a candidate hasn't been named, ask who this is about (use find_candidate to resolve them). ";
  if (name === "candidate_intake") {
    return { description: "Candidate intake from call", ...msg(candCtx + "Turn a candidate call into Octagon's intake template. Ask the recruiter to paste their call notes or the Devyce transcript. Fill in as many of these fields as the notes support, leaving a field BLANK when it wasn't covered (don't guess): current situation; reason for leaving / what's missing in current role; current company; key product area/specialisms + which industries they're sold to; top skills/responsibilities; previous manager & best recruitment contact; current salary & salary expectation; notice period & benefits; willing to relocate (+ radius); family situation; nationality/security clearance; sponsorship required (+ details); contractor rate & available from; employment preference; past roles (RFL? £? contacts); ideal role/responsibilities; target companies & companies/industries to avoid; where else they're interviewing (capture as LEADS); additional notes. Then: (1) list the fields left blank or weak, (2) give a short 'ask next time' checklist to close those gaps, and (3) if the recruiter's token can write, offer to save this as a note on the candidate via add_note. Candidate details are PII — keep internal.") };
  }
  if (name === "candidate_summary") {
    return { description: "Candidate summary (sell to client)", ...msg(candCtx + "Write a client-facing candidate summary that SELLS the candidate for a role. Ask the recruiter to paste the intake notes / CV highlights and confirm which job/client this is for. Produce a concise, professional summary the consultant can send to the client: a headline (who they are + why they fit), key skills/experience mapped to the role's requirements, relevant achievements, availability & notice, and salary expectation ONLY if the recruiter wants it shared. End with a one-line 'why now'. Keep it honest — don't invent detail; flag anything to confirm. Omit sensitive personal fields (family, nationality, clearance) unless the role genuinely requires them.") };
  }
  if (name === "candidate_thankyou") {
    return { description: "Post-call thank-you email", ...msg(candCtx + "Draft a warm post-call thank-you email to the candidate. Ask which role/client it's for and for the job spec plus a couple of company highlights if not already provided. The email should thank them for their time, recap why this opportunity suits them, summarise the job spec, share a couple of exciting things about the company, and lay out the next steps — leaving them genuinely excited to proceed. Friendly, professional, concise. Give a subject line, and don't invent facts about the company or role you weren't told.") };
  }
  if (name === "interview_prep") {
    return { description: "Interview-prep email", ...msg(candCtx + "Write an interview-preparation email for a candidate who's been requested for interview. Ask for the job/client and the interview time, date and location/format if not provided. Include: confirmation of the scheduled time/date and location or video link; who they'll be meeting; how to dress; how to prepare (company & role research pointers, likely themes); a few strong questions for them to ask; and any logistics / what to bring. Encouraging and confidence-building. Give a subject line, and leave clear [placeholders] for any interview details you weren't given rather than inventing them.") };
  }
  const clientArg = (args?.client ?? "").toString().trim();
  const companyArg = (args?.company ?? "").toString().trim();
  if (name === "client_update") {
    const cl = clientArg || "the client";
    return { description: "Weekly client update", ...msg(`Draft a weekly client update email for ${cl}. First gather the live picture: call client_report with client='${clientArg}' for 2026 year-to-date, and job_pipeline for their open role(s) to see who's in play and at what stage. Then write the email: (1) what we've done this week (CVs sent, interviews arranged, candidates in play per role), (2) the push & pull — what's going well and where we're blocked (e.g. awaiting feedback, spec/salary mismatch, market scarcity), (3) what we could do to find more (concrete next steps from the vacancy checklist — wider search, competitor mapping, referrals). Warm, professional, concise; give a subject line. Keep internal pipeline detail at a level appropriate to share with a client.`) };
  }
  if (name === "pipeline_chase") {
    const j = (args?.job ?? "").toString().trim();
    const src = j ? `Call job_pipeline with job='${j}' to see who's been submitted and their current stage.` : "Call stalled_report to find aging offers and stalled candidates on open roles firm-wide.";
    return { description: "Pipeline chase", ...msg(`Find candidate submissions that have stalled with the client and draft chase-ups. ${src} For each candidate who has been sent / waiting more than a few days with no movement, draft a short, friendly chase message to the client asking for feedback or the next step, referencing the specific candidate and role. Lead with the most overdue. Keep each message brief and easy to say yes to. Candidate names appear here only where already shared with that client.`) };
  }
  if (name === "bd_pitch") {
    const co = companyArg || "the target company";
    return { description: "BD call pitch", ...msg(`Create a BD cold-call pitch for a target contact at ${co}. Ask the consultant for the contact's name/role and anything known about the company if not provided. Build natural spoken talking points: a strong opener (why we're calling), Octagon's relevant track record and the calibre of candidates we have in their space, the value proposition, and a clear ask (a quick intro call, or permission to send a strong candidate). Then give 2-3 likely objections (already using an agency / on a PSL / no roles right now / send terms) with confident, non-pushy responses. Keep it conversational, not a script to read robotically.`) };
  }
  if (name === "bd_targets") {
    return { description: "BD targets", ...msg("Identify and prioritise key BD targets. Call bd_report for the company/BD funnel (Prospect / Engaged / Client / Passive / etc.). Highlight the best opportunities to pursue — e.g. warm prospects with no recent engagement, or sectors where we are candidate-rich (cross-reference match_candidates if useful). Produce a prioritised BD call list with a one-line reason for each, and suggest the single best target to start with today.") };
  }
  if (name === "spec_pitch") {
    return { description: "Speculative candidate pitch", ...msg(candCtx + "Create a speculative pitch to place a strong candidate. If a candidate is named, use find_candidate for context; otherwise help the consultant pick a strong, placeable candidate (e.g. someone recently interviewed well or a hot skill set). Produce: (1) an ANONYMISED candidate teaser to send to target clients — sellable highlights (skills, achievements, availability, salary ballpark) with NO name or current employer, and (2) a short email pitch to a prospective client offering a confidential introduction. Then name the types of companies / specific accounts to target. The goal is to get clients interested enough to engage before any identity is revealed.") };
  }
  return null;
}

const rpc = (id: any, result: any) => ({ jsonrpc: "2.0", id, result });
const rpcErr = (id: any, code: number, message: string) => ({ jsonrpc: "2.0", id, error: { code, message } });
const toolText = (o: any) => ({ content: [{ type: "text", text: JSON.stringify(o) }] });
const widgetResult = (data: any, uri: string, summary: string) => ({ content: [{ type: "text", text: summary }], structuredContent: data, _meta: { ui: { resourceUri: uri } } });
async function consultantName(id: any): Promise<string | null> {
  if (!id) return null;
  const { data } = await db.from("consultants").select("name").eq("recruitcrm_id", id).maybeSingle();
  return data?.name ?? null;
}

async function callTool(name: string, args: any, req: Request) {
  // Every tool requires a valid token.
  const auth = await authenticate(req, args);
  if (!auth.ok) return toolText({ error: auth.reason });
  const actor = auth.actor;
  logCall(actor.id, name);

  if (name === "get_dashboard") {
    const { data, error } = await db.rpc("dashboard_json");
    if (error) return toolText({ error: error.message });
    // Identity-aware scoping: firm totals (KPIs/funnel/pipeline/health) for everyone; the per-recruiter
    // breakdown only for admins/managers. A recruiter instead gets their OWN desk — week vs target,
    // quarterly billing, their 2026 funnel, and the attention list (aging offers / stalled) that
    // my_day computes. Note: the attention list carries candidate names, so this tool is no longer
    // PII-free for a recruiter viewing their own desk.
    // actor.id 0 is the admin sentinel (no consultant record) — compare against null, not truthiness.
    let viewerName: string | null = null;
    if (actor.id != null) { const { data: c } = await db.from("consultants").select("name").eq("recruitcrm_id", actor.id).maybeSingle(); viewerName = c?.name ?? null; }
    const [{ data: wk }, { data: bill }] = await Promise.all([db.rpc("kpis_report"), db.rpc("billing_report")]);
    const byName = (rows: any) => (rows ?? []).find((x: any) => x.name === viewerName) ?? null;
    const myWeekly = viewerName ? byName(wk?.consultants) : null;
    const myBilling = viewerName ? byName(bill?.consultants) : null;
    const my2026 = viewerName ? byName(data?.consultants) : null;
    // The desk view is for recruiters only; admins keep the firm/team layout and don't need my_day here.
    let myDay: any = null;
    if (viewerName && !actor.is_admin) {
      const { data: md } = await db.rpc("my_day", { p_consultant_id: actor.id, p_consultant: null });
      myDay = md && !md.error ? md : null;
    }
    // Untagged Devyce calls can't count toward the BD/client targets (the split keys off
    // custom_call_type), and firm-wide only ~27% are tagged. Show the recruiter their own tagging
    // rate next to the KPI it depresses, so a red number reads as "tag your calls", not "call more".
    let myCalls: any = null;
    if (viewerName && !actor.is_admin && wk?.week_start) {
      const scoped = () => db.from("call_activity").select("*", { count: "exact", head: true })
        .eq("consultant_recruitcrm_id", actor.id).gte("call_date", wk.week_start);
      const [{ count: logged }, { count: tagged }] = await Promise.all([
        scoped(), scoped().not("custom_call_type", "is", null).neq("custom_call_type", ""),
      ]);
      myCalls = { logged: logged ?? 0, tagged: tagged ?? 0 };
    }
    data.viewer = {
      name: viewerName ?? (actor.is_admin ? "Admin" : null), is_admin: !!actor.is_admin,
      week_start: wk?.week_start ?? null, quarter_start: bill?.quarter_start ?? null,
      my_weekly: myWeekly, my_billing: myBilling, my_2026: my2026, my_day: myDay, my_calls: myCalls,
    };
    if (!actor.is_admin) delete data.consultants;   // hide the whole-team per-recruiter breakdown from regular recruiters
    // MCP Apps: structuredContent drives the inline widget; content is the model-facing fallback.
    const k = data?.kpis ?? {};
    // Text is the model-facing DATA (not a claim that a widget rendered) — so the recruiter still
    // gets the figures even if the inline widget is slow/unsupported. A recruiter's summary leads
    // with their own desk; the firm line follows.
    const gbp = (n: any) => `£${Math.round(Number(n ?? 0)).toLocaleString("en-GB")}`;
    const firmLine = `Firm — placed 2026: ${k.placed_2026 ?? "?"}, all-time: ${k.placed_all ?? "?"}; open jobs: ${k.open_jobs ?? "?"}; open pipeline ${gbp(k.open_pipeline)}; Won ${gbp(k.won)}; sync ${data?.health?.overall ?? "?"}.`;
    let summary = firmLine;
    if (viewerName && !actor.is_admin) {
      const behind = (["cv_sent", "interview_request", "first_interview", "bd_calls", "client_calls"] as const)
        .map((m) => ({ m, a: myWeekly?.[m]?.actual ?? 0, t: myWeekly?.[m]?.target }))
        .filter((x) => x.t != null && x.a < x.t).map((x) => `${x.m} ${x.a}/${x.t}`).join(", ");
      const parts = [
        `${viewerName} — this week (from ${wk?.week_start ?? "?"}): ${behind ? `behind on ${behind}` : "all weekly targets met"}.`,
        `Billing this quarter ${gbp(myBilling?.won_qtr)}${myBilling?.quarterly_target != null ? ` of ${gbp(myBilling.quarterly_target)}` : ""}, open pipeline ${gbp(myBilling?.pipeline_open)}.`,
        myDay ? `Attention: ${(myDay.aging_offers ?? []).length} aging offer(s), ${(myDay.stalled ?? []).length} stalled, ${myDay.cold_open_roles ?? 0} cold open role(s), ${myDay.active_in_play ?? 0} active in play, ${myDay.placed_last_7d ?? 0} placed in the last 7 days.` : "",
        myCalls?.logged ? `Calls logged this week ${myCalls.logged}, tagged ${myCalls.tagged} (${Math.round(100 * myCalls.tagged / myCalls.logged)}%) — untagged calls cannot count toward the BD/client targets.` : "",
      ];
      summary = parts.filter(Boolean).join(" ") + " " + firmLine;
    }
    return { content: [{ type: "text", text: summary }], structuredContent: data, _meta: { ui: { resourceUri: DASH_UI } } };
  }
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
  if (name === "weekly_kpis") {
    const { data, error } = await db.rpc("kpis_report");
    if (error) return toolText({ error: error.message });
    if (!actor.is_admin) { const vn = await consultantName(actor.id); data.consultants = (data.consultants ?? []).filter((x: any) => x.name === vn); }
    return widgetResult(data, SCORE_UI, `Weekly KPI scorecard (inline widget): ${(data.consultants ?? []).length} recruiter(s), week from ${data.week_start ?? "?"}.`);
  }
  if (name === "billing") {
    const { data, error } = await db.rpc("billing_report");
    if (error) return toolText({ error: error.message });
    if (!actor.is_admin) { const vn = await consultantName(actor.id); data.consultants = (data.consultants ?? []).filter((x: any) => x.name === vn); }
    return widgetResult(data, SCORE_UI, `Quarterly billing scorecard (inline widget): ${(data.consultants ?? []).length} recruiter(s), quarter from ${data.quarter_start ?? "?"}.`);
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
  if (method === "initialize") return rpc(id, { protocolVersion: params?.protocolVersion || "2025-06-18", capabilities: { tools: {}, prompts: {}, resources: {}, extensions: { "io.modelcontextprotocol/ui": { mimeTypes: [MCP_APP_MIME] } } }, serverInfo: SERVER });
  if (method === "resources/list") return rpc(id, { resources: [
    { uri: DASH_UI, name: "octagon_dashboard", mimeType: MCP_APP_MIME },
    { uri: SCORE_UI, name: "octagon_scorecard", mimeType: MCP_APP_MIME },
  ] });
  if (method === "resources/read") {
    if (params?.uri === DASH_UI) return rpc(id, { contents: [{ uri: DASH_UI, mimeType: MCP_APP_MIME, text: DASHBOARD_WIDGET_HTML }] });
    if (params?.uri === SCORE_UI) return rpc(id, { contents: [{ uri: SCORE_UI, mimeType: MCP_APP_MIME, text: SCORECARD_WIDGET_HTML }] });
    return rpcErr(id, -32602, "Unknown resource: " + params?.uri);
  }
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

// ---- OAuth 2.1 bridge --------------------------------------------------------------------------
// claude.ai's connector requires OAuth. We speak it, but the "login" is simply: paste your Octagon
// token -> we validate it against mcp_tokens -> issue an OAuth access token (also stored in
// mcp_tokens) mapped to that consultant. So claude.ai gets OAuth; we keep per-user identity.
const OAUTH_BASE = "https://kzcmssldvtjnbwwunuwm.supabase.co/functions/v1/octagon-mcp";
const CORS: Record<string, string> = { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "*", "Access-Control-Allow-Methods": "POST, GET, OPTIONS" };
const AS_METADATA = { issuer: OAUTH_BASE, authorization_endpoint: `${OAUTH_BASE}/authorize`, token_endpoint: `${OAUTH_BASE}/token`, registration_endpoint: `${OAUTH_BASE}/register`, response_types_supported: ["code"], grant_types_supported: ["authorization_code"], code_challenge_methods_supported: ["S256"], token_endpoint_auth_methods_supported: ["none"], scopes_supported: ["mcp"] };
const PR_METADATA = { resource: OAUTH_BASE, authorization_servers: [OAUTH_BASE], scopes_supported: ["mcp"], bearer_methods_supported: ["header"] };

async function sha256b64url(s: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  let bin = ""; for (const b of new Uint8Array(buf)) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
function randToken(n = 32) { const a = new Uint8Array(n); crypto.getRandomValues(a); return Array.from(a).map((b) => b.toString(16).padStart(2, "0")).join(""); }
async function validateOctagonToken(token: string) {
  const t = (token || "").trim(); if (!t) return null;
  const { data } = await db.from("mcp_tokens").select("consultant_recruitcrm_id,can_write,is_admin").eq("token_hash", await sha256hex(t)).eq("active", true).maybeSingle();
  return data ?? null;
}
// Supabase can't serve rendered HTML (text/plain + nosniff on the *.supabase.co domain), so the
// login form is hosted off-Supabase and just POSTs back here. GET hands off to it; POST does the work.
const LOGIN_URL = "https://octagongroup.co.uk/octagon-connect.html/";
const OAUTH_PASSTHRU = ["client_id", "redirect_uri", "state", "code_challenge", "code_challenge_method", "response_type", "scope", "resource"];
async function handleAuthorize(req: Request): Promise<Response> {
  const u = new URL(req.url);
  if (req.method === "GET") {
    const p: Record<string, string> = {}; for (const k of u.searchParams.keys()) p[k] = u.searchParams.get(k) ?? "";
    if (p.response_type !== "code" || !p.redirect_uri || !p.code_challenge || p.code_challenge_method !== "S256") return new Response("invalid_request: need response_type=code, redirect_uri, and S256 PKCE", { status: 400, headers: { "Content-Type": "text/plain" } });
    if (!/^https:\/\//.test(p.redirect_uri) && !/^http:\/\/localhost[:/]/.test(p.redirect_uri)) return new Response("invalid redirect_uri", { status: 400, headers: { "Content-Type": "text/plain" } });
    const dest = new URL(LOGIN_URL); for (const k of OAUTH_PASSTHRU) if (p[k]) dest.searchParams.set(k, p[k]);
    return new Response(null, { status: 302, headers: { Location: dest.toString() } });
  }
  const form = new URLSearchParams(await req.text()); const p: Record<string, string> = {}; for (const [k, v] of form) p[k] = v;
  const who = await validateOctagonToken(p.token ?? "");
  if (!who) {
    const back = new URL(LOGIN_URL); back.searchParams.set("error", "1"); for (const k of OAUTH_PASSTHRU) if (p[k]) back.searchParams.set(k, p[k]);
    return new Response(null, { status: 302, headers: { Location: back.toString() } });
  }
  const code = randToken(24);
  // Carry is_admin through the exchange alongside can_write, or re-authenticating silently demotes
  // an admin to the recruiter view.
  await db.from("oauth_codes").insert({ code, consultant_recruitcrm_id: who.consultant_recruitcrm_id, can_write: !!who.can_write, is_admin: !!who.is_admin, code_challenge: p.code_challenge, redirect_uri: p.redirect_uri, expires_at: new Date(Date.now() + 5 * 60 * 1000).toISOString() });
  const redir = new URL(p.redirect_uri); redir.searchParams.set("code", code); if (p.state) redir.searchParams.set("state", p.state);
  return new Response(null, { status: 302, headers: { Location: redir.toString() } });
}
async function handleToken(req: Request): Promise<Response> {
  const raw = await req.text(); let body: Record<string, string> = {};
  if ((req.headers.get("content-type") || "").includes("application/json")) { try { body = JSON.parse(raw); } catch { /* */ } }
  else { for (const [k, v] of new URLSearchParams(raw)) body[k] = v; }
  const err = (e: string, d = "") => new Response(JSON.stringify({ error: e, error_description: d }), { status: 400, headers: CORS });
  if (body.grant_type !== "authorization_code") return err("unsupported_grant_type", "only authorization_code");
  if (!body.code || !body.code_verifier || !body.redirect_uri) return err("invalid_request", "code, code_verifier, redirect_uri required");
  const { data: rec } = await db.from("oauth_codes").select("*").eq("code", body.code).maybeSingle();
  if (!rec) return err("invalid_grant", "unknown or used code");
  await db.from("oauth_codes").delete().eq("code", body.code);
  if (new Date(rec.expires_at).getTime() < Date.now()) return err("invalid_grant", "code expired");
  if (rec.redirect_uri !== body.redirect_uri) return err("invalid_grant", "redirect_uri mismatch");
  if ((await sha256b64url(body.code_verifier)) !== rec.code_challenge) return err("invalid_grant", "PKCE verification failed");
  const accessToken = "oct_oauth_" + randToken(24);
  await db.from("mcp_tokens").insert({ token_hash: await sha256hex(accessToken), consultant_recruitcrm_id: rec.consultant_recruitcrm_id, can_write: rec.can_write, is_admin: !!rec.is_admin, label: "oauth-session", active: true });
  return new Response(JSON.stringify({ access_token: accessToken, token_type: "Bearer", expires_in: 7776000, scope: "mcp" }), { headers: CORS });
}
async function handleRegister(req: Request): Promise<Response> {
  let body: any = {}; try { body = JSON.parse(await req.text()); } catch { /* */ }
  return new Response(JSON.stringify({ client_id: "octagon-" + randToken(8), token_endpoint_auth_method: "none", grant_types: ["authorization_code"], response_types: ["code"], redirect_uris: Array.isArray(body?.redirect_uris) ? body.redirect_uris : [], client_name: body?.client_name ?? "octagon-connector" }), { status: 201, headers: CORS });
}

Deno.serve(async (req) => {
  const headers = CORS;
  const path = new URL(req.url).pathname;
  if (req.method === "OPTIONS") return new Response(null, { headers });

  // OAuth 2.1 bridge endpoints
  if (path.endsWith("/.well-known/oauth-authorization-server") || path.endsWith("/.well-known/openid-configuration")) return new Response(JSON.stringify(AS_METADATA), { headers });
  if (path.endsWith("/.well-known/oauth-protected-resource")) return new Response(JSON.stringify(PR_METADATA), { headers });
  if (path.endsWith("/register") && req.method === "POST") return handleRegister(req);
  if (path.endsWith("/authorize")) return handleAuthorize(req);
  if (path.endsWith("/token") && req.method === "POST") return handleToken(req);

  if (req.method === "GET") return new Response(JSON.stringify({ name: SERVER.name, version: SERVER.version, transport: "streamable-http" }), { headers });

  // MCP JSON-RPC (POST): require a valid bearer token, else a 401 challenge that points claude.ai
  // at the OAuth flow above.
  const auth = await authenticate(req, {});
  if (!auth.ok) return new Response(JSON.stringify(rpcErr(null, -32001, "Unauthorized")), { status: 401, headers: { ...headers, "WWW-Authenticate": `Bearer resource_metadata="${OAUTH_BASE}/.well-known/oauth-protected-resource"` } });

  let msg: any; try { msg = await req.json(); } catch { return new Response(JSON.stringify(rpcErr(null, -32700, "Parse error")), { headers }); }
  if (Array.isArray(msg)) { const out = (await Promise.all(msg.map((x) => handle(x, req)))).filter((x) => x !== null); return new Response(out.length ? JSON.stringify(out) : "", { status: out.length ? 200 : 202, headers }); }
  const res = await handle(msg, req);
  if (res === null) return new Response("", { status: 202, headers });
  return new Response(JSON.stringify(res), { headers });
});
