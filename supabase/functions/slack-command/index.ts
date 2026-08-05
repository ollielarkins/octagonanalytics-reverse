// slack-command — team-wide Slack slash commands: /dashboard and /kpis.
//
// Slack gives slash commands a 3s reply budget, so we ACK immediately and deliver the
// result via response_url. Signature is verified before we trust anything (incl. the
// response_url we POST to). Report functions are called over PostgREST rpc with the
// service-role key — no heavy imports, minimal cold start.
//
//   /dashboard            -> the standard live dashboard (same as the start-of-chat one)
//   /dashboard <text>     -> a specific view; the text is routed by keyword / month /
//                            consultant name (funnel, bd, calls, leaderboard, cold,
//                            time-to-fill, client, kpis). Unrecognised -> overview + note.
//   /kpis                 -> this-week actuals vs weekly targets, per recruiter
//
// Setup (admin): Supabase secret SLACK_SIGNING_SECRET; add both slash commands in the
// Slack app pointing at /functions/v1/slack-command.

const SB = Deno.env.get("SUPABASE_URL")!;
const KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

async function rpc(fn: string, args: Record<string, unknown> = {}) {
  const r = await fetch(`${SB}/rest/v1/rpc/${fn}`, {
    method: "POST",
    headers: { apikey: KEY, Authorization: `Bearer ${KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify(args),
  });
  return await r.json();
}
async function consultants(): Promise<{ name: string }[]> {
  const r = await fetch(`${SB}/rest/v1/consultants?select=name&deleted_at=is.null`, { headers: { apikey: KEY, Authorization: `Bearer ${KEY}` } });
  return (await r.json()) ?? [];
}

async function hmacHex(secret: string, msg: string): Promise<string> {
  const k = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const s = await crypto.subtle.sign("HMAC", k, new TextEncoder().encode(msg));
  return Array.from(new Uint8Array(s)).map((b) => b.toString(16).padStart(2, "0")).join("");
}
function timingEq(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let r = 0; for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}
const num = (n: any) => (Number(n) || 0).toLocaleString("en-GB");
const gbp = (n: any) => "£" + (Math.round(Number(n) || 0)).toLocaleString("en-GB");
const pct = (x: any) => x == null ? "—" : Math.round(Number(x) * 100) + "%";

const MONTHS = ["january","february","march","april","may","june","july","august","september","october","november","december"];
function parseWindow(t: string): { from: string; to: string; label: string } | null {
  const mkeys = (y: number, m: number) => ({ from: `${y}-${String(m).padStart(2,"0")}-01`, to: m===12?`${y+1}-01-01`:`${y}-${String(m+1).padStart(2,"0")}-01`, label: `${MONTHS[m-1]} ${y}` });
  let mm = t.match(/(\d{4})-(\d{2})/);
  if (mm) { const y=+mm[1], m=+mm[2]; return { from:`${y}-${mm[2]}-01`, to: m===12?`${y+1}-01-01`:`${y}-${String(m+1).padStart(2,"0")}-01`, label: `${MONTHS[m-1]} ${y}` }; }
  const yr = (t.match(/\b(20\d{2})\b/) || [])[1];
  const y = yr ? +yr : 2026;
  const q = t.match(/\bq([1-4])\b/);
  if (q) { const s = (+q[1]-1)*3+1; return { from:`${y}-${String(s).padStart(2,"0")}-01`, to: s+3>12?`${y+1}-01-01`:`${y}-${String(s+3).padStart(2,"0")}-01`, label:`Q${q[1]} ${y}` }; }
  for (let i=0;i<12;i++){ if (t.includes(MONTHS[i]) || t.includes(MONTHS[i].slice(0,3))) return mkeys(y, i+1); }
  if (t.includes("this year")) return { from:`${y}-01-01`, to:`${y+1}-01-01`, label:`${y}` };
  if (yr) return { from:`${y}-01-01`, to:`${y+1}-01-01`, label:`${y}` };
  return null;
}

// ---- formatters (Slack mrkdwn) ----
function fmtDashboard(D: any): string {
  const k = D.kpis ?? {}, f = D.funnel ?? {}, h = D.health ?? {};
  const conv = k.cv_2026 ? ((k.placed_2026 / k.cv_2026) * 100).toFixed(1) + "%" : "—";
  const top = (D.consultants ?? []).slice(0, 3).map((c: any) => `${c.name} ${c.cv_sent}`).join(" · ") || "—";
  const stale = h.overall && h.overall !== "ok" ? `  :warning: sync ${h.overall}` : "";
  return [`*Octagon dashboard*${stale}`,
    `KPIs 2026: ${num(k.cv_2026)} CVs · ${num(k.placed_2026)} placed (${conv}) · ${num(k.open_jobs)}/${num(k.jobs)} open jobs · ${num(k.clients)} clients`,
    `Funnel: CV ${num(f.cv_sent)} → IR ${num(f.interview_request)} → 1st ${num(f.first_interview)} → 2nd ${num(f.second_interview)} → 3rd ${num(f.third_interview)} → Offer ${num(f.offered)} → Placed ${num(f.placed)}`,
    `Top consultants (CVs): ${top}`,
    `Pipeline: open ${gbp(k.open_pipeline)} · won ${gbp(k.won)}`].join("\n");
}
function fmtFunnel(f: any): string {
  const t = f.totals ?? {}, w = f.filters ?? {};
  const who = w.consultant ? ` — ${w.consultant}` : "";
  return `*Funnel${who}* (${f.window?.from} to ${f.window?.to})\nCV ${num(t.cv_sent)} → IR ${num(t.interview_request)} → 1st ${num(t.first_interview)} → 2nd ${num(t.second_interview)} → 3rd ${num(t.third_interview)} → Offer ${num(t.offered)} → Placed ${num(t.placed)}\nCV→1st ${pct(t.cv_to_first_interview_pct)} · CV→placed ${pct(t.cv_to_placed_pct)}`;
}
function fmtBd(b: any): string {
  const rows = (b.by_status ?? []).map((s: any) => `${s.status}: ${num(s.companies)}`).join(" · ");
  return `*BD / client funnel* (${num(b.classified)} of ${num(b.total_companies)} classified)\n${rows}`;
}
function fmtCalls(c: any): string {
  const t = c.totals ?? {};
  const top = (c.by_consultant ?? []).slice(0,5).map((x: any) => `${x.name} ${num(x.calls)}`).join(" · ");
  return `*Call activity* (${c.window?.from} to ${c.window?.to})\n${num(t.calls)} calls · ${pct(t.connect_rate)} connected · ${num(t.talk_minutes)} talk-min\nTop callers: ${top}`;
}
function fmtLeaderboard(l: any): string {
  const rows = (l.leaderboard ?? []).slice(0,8).map((x: any, i: number) => `${i+1}. ${x.name} — ${num(x.placed)} placed, ${num(x.cv_sent)} CVs`).join("\n");
  return `*Leaderboard* (ranked by ${l.ranked_by}, ${l.window?.from} to ${l.window?.to})\n${rows}`;
}
function fmtCold(c: any): string {
  const rows = (c.jobs ?? []).slice(0,8).map((j: any) => `• ${j.job_title}${j.client?` (${j.client})`:""} — ${j.days_since_activity ?? "no"} days`).join("\n");
  return `*Cold open roles* (${num(c.cold_count)} total, >${c.threshold_days}d)\n${rows}`;
}
function fmtTTF(t: any): string {
  const d = t.days ?? {};
  return `*Time to fill* (${t.window?.from} to ${t.window?.to})\n${num(t.placements_measured)} placements · avg ${num(d.avg)}d · median ${num(d.median)}d`;
}
function fmtClient(c: any): string {
  const rows = (c.clients ?? []).slice(0,8).map((x: any) => `• ${x.client} — ${num(x.cv_sent)} CVs, ${num(x.placed)} placed, ${num(x.open_jobs)} open`).join("\n");
  return `*Client activity*\n${rows}`;
}
function fmtKpis(k: any): string {
  const cell = (m: any) => `${num(m?.actual)}${m?.target!=null?`/${num(m.target)}`:""}`;
  const lines = (k.consultants ?? []).map((c: any) =>
    `• ${c.name} — CVs ${cell(c.cv_sent)} · Calls ${cell(c.calls)} · 1st ${cell(c.first_interview)} · Placed ${cell(c.placed)}`).join("\n");
  const hdr = `*Weekly KPIs* (week of ${k.week_start}) — actual${k.has_targets?"/target":""}`;
  const note = k.has_targets ? "" : "\n_No targets loaded yet — showing actuals only._";
  return `${hdr}${note}\n${lines}`;
}

async function routeDashboard(text: string): Promise<string> {
  const t = text.toLowerCase().trim();
  const w = parseWindow(t);
  const from = w?.from ?? "2026-01-01", to = w?.to ?? "2100-01-01";
  if (/\bkpi|target/.test(t)) return fmtKpis(await rpc("kpis_report"));
  if (/\bbd\b|prospect|client status|account status/.test(t)) return fmtBd(await rpc("bd_report"));
  if (/call|dial|talk ?time/.test(t)) return fmtCalls(await rpc("call_activity_report", { p_from: from, p_to: to, p_consultant: null, p_team: null }));
  if (/leaderboard|top perform|ranking|rank /.test(t)) return fmtLeaderboard(await rpc("consultant_leaderboard", { p_from: from, p_to: to, p_metric: "placed", p_limit: 8 }));
  if (/\bcold\b|stale/.test(t)) return fmtCold(await rpc("cold_jobs", { p_days: 14, p_consultant: null, p_limit: 8 }));
  if (/time.?to.?fill|\bttf\b/.test(t)) return fmtTTF(await rpc("time_to_fill", { p_from: from, p_to: to, p_consultant: null, p_team: null }));
  if (/client|account/.test(t)) return fmtClient(await rpc("client_report", { p_from: from, p_to: to, p_client: null, p_limit: 8 }));
  // consultant name?
  const cons = await consultants();
  const hit = cons.find((c) => (c.name || "").toLowerCase().split(/\s+/).some((part) => part.length > 2 && t.includes(part)));
  if (hit) return fmtFunnel(await rpc("funnel_report", { p_from: from, p_to: to, p_consultant: hit.name, p_team: null }));
  if (w) return fmtFunnel(await rpc("funnel_report", { p_from: from, p_to: to, p_consultant: null, p_team: null }));
  // fallback
  return fmtDashboard(await rpc("dashboard_json")) + `\n_(didn't recognise "${text}" — showing the overview. Try a month, a consultant, or: bd, calls, leaderboard, cold, time to fill, client, kpis.)_`;
}

async function deliver(command: string, text: string, responseUrl: string) {
  let out: string;
  try {
    if (command === "/kpis") out = fmtKpis(await rpc("kpis_report"));
    else if (text && text.trim()) out = await routeDashboard(text);
    else out = fmtDashboard(await rpc("dashboard_json"));
  } catch (e) {
    out = "Couldn't build that right now: " + String(e).slice(0, 150);
  }
  await fetch(responseUrl, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ response_type: "in_channel", text: out }) });
}

Deno.serve(async (req) => {
  if (req.method === "GET") return new Response(JSON.stringify({ name: "octagon-slack-command", ok: true }), { headers: { "Content-Type": "application/json" } });
  if (req.method !== "POST") return new Response("method not allowed", { status: 405 });

  const secret = Deno.env.get("SLACK_SIGNING_SECRET");
  if (!secret) return new Response(JSON.stringify({ response_type: "ephemeral", text: "Slack command isn't configured yet: SLACK_SIGNING_SECRET is not set in Supabase." }), { status: 200, headers: { "Content-Type": "application/json" } });

  const raw = await req.text();
  const ts = req.headers.get("x-slack-request-timestamp") ?? "";
  const sig = req.headers.get("x-slack-signature") ?? "";
  if (!ts || Math.abs(Date.now() / 1000 - Number(ts)) > 300) return new Response("stale or missing timestamp", { status: 401 });
  const expected = "v0=" + await hmacHex(secret, `v0:${ts}:${raw}`);
  if (!timingEq(expected, sig)) return new Response("bad signature", { status: 401 });

  const params = new URLSearchParams(raw);
  const command = params.get("command") ?? "/dashboard";
  const text = params.get("text") ?? "";
  const responseUrl = params.get("response_url") ?? "";
  if (responseUrl) { try { (globalThis as any).EdgeRuntime?.waitUntil(deliver(command, text, responseUrl)); } catch { deliver(command, text, responseUrl); } }

  const ack = command === "/kpis" ? "Pulling this week's KPIs…" : (text && text.trim() ? `Building "${text}"…` : "Fetching the live dashboard…");
  return new Response(JSON.stringify({ response_type: "ephemeral", text: ack }), { status: 200, headers: { "Content-Type": "application/json" } });
});
