// digest-email — renders and sends the scheduled Octagon digests.
//
// Three kinds, chosen from measured behaviour (see migration 0071):
//   morning  07:30 Mon-Fri  forward-looking, lands before the 43.5% of daily activity that
//                           happens before 10:00 and is therefore the only one that can change
//                           what someone does today
//   evening  17:30 Mon-Fri  backward-looking, sent once activity is 99.6% done for the day
//   weekly   08:00 Mon      the slow movers: cold roles, job order forms, last week closed out
//
// A midday digest was deliberately NOT built. It would capture ~68% of the day (incomplete),
// arrive after the morning it might have influenced, and repeat itself at 17:30.
//
// Email HTML is deliberately old-fashioned: tables, inline styles, no flexbox, no <style> block,
// no web fonts, 600px fixed. Outlook renders with Word's engine and silently drops modern CSS.
// Colours are stated explicitly on every cell because email dark mode inverts unstyled elements
// unpredictably and a half-inverted table is unreadable.
//
// Sending needs RESEND_API_KEY. Without it the function returns 200 with sent:false and says so —
// it must not fail the cron, and it must not pretend to have sent something it did not.

import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const RESEND_KEY = (Deno.env.get("RESEND_API_KEY") ?? "").trim();
const MAIL_FROM = (Deno.env.get("DIGEST_FROM") ?? "Octagon Analytics <onboarding@resend.dev>").trim();

const db = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });

// ---------- small helpers ----------
const esc = (s: unknown) =>
  String(s ?? "").replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));

const gbp = (n: unknown) => {
  const v = Number(n);
  if (!isFinite(v)) return "—";
  return "£" + v.toLocaleString("en-GB", { maximumFractionDigits: 0 });
};

const ddmmyyyy = (d: unknown) => {
  if (!d) return "—";
  const dt = new Date(String(d));
  if (isNaN(dt.getTime())) return String(d);
  const p = (n: number) => String(n).padStart(2, "0");
  return `${p(dt.getUTCDate())}/${p(dt.getUTCMonth() + 1)}/${dt.getUTCFullYear()}`;
};

const dayLabel = (d: unknown) => {
  const dt = new Date(String(d));
  if (isNaN(dt.getTime())) return "";
  const days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
  const p = (n: number) => String(n).padStart(2, "0");
  return `${days[dt.getUTCDay()]} ${p(dt.getUTCDate())}/${p(dt.getUTCMonth() + 1)}`;
};

// ---------- palette ----------
const C = {
  page: "#eef0f4",
  card: "#ffffff",
  ink: "#141922",
  muted: "#5b6472",
  faint: "#8b93a1",
  line: "#e2e6ec",
  accent: "#1d4ed8",
  warn: "#b45309",
  warnBg: "#fff7ed",
  good: "#047857",
  headBg: "#141922",
};

// ---------- building blocks ----------
function stat(label: string, value: string | number, sub?: string) {
  return `<td align="center" style="padding:14px 8px;background:${C.card};border:1px solid ${C.line};border-radius:8px;">
    <div style="font:700 26px/1.1 -apple-system,BlinkMacSystemFont,'Segoe UI',Arial,sans-serif;color:${C.ink};">${esc(value)}</div>
    <div style="font:600 10px/1.4 -apple-system,BlinkMacSystemFont,'Segoe UI',Arial,sans-serif;color:${C.faint};text-transform:uppercase;letter-spacing:.6px;padding-top:4px;">${esc(label)}</div>
    ${sub ? `<div style="font:400 11px/1.4 -apple-system,BlinkMacSystemFont,'Segoe UI',Arial,sans-serif;color:${C.muted};padding-top:2px;">${esc(sub)}</div>` : ""}
  </td>`;
}

function statRow(cells: string[]) {
  const gap = `<td style="width:8px;font-size:0;line-height:0;">&nbsp;</td>`;
  return `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 18px;">
    <tr>${cells.join(gap)}</tr></table>`;
}

function section(title: string, body: string, note?: string) {
  return `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 18px;background:${C.card};border:1px solid ${C.line};border-radius:8px;">
    <tr><td style="padding:14px 16px 10px;">
      <div style="font:700 13px/1.3 -apple-system,BlinkMacSystemFont,'Segoe UI',Arial,sans-serif;color:${C.ink};letter-spacing:.2px;">${esc(title)}</div>
      ${note ? `<div style="font:400 11px/1.5 -apple-system,BlinkMacSystemFont,'Segoe UI',Arial,sans-serif;color:${C.muted};padding-top:3px;">${esc(note)}</div>` : ""}
    </td></tr>
    <tr><td style="padding:0 16px 14px;">${body}</td></tr>
  </table>`;
}

function table(headers: string[], rows: (string | number)[][], aligns: string[] = []) {
  if (!rows.length) {
    return `<div style="font:400 13px/1.5 -apple-system,BlinkMacSystemFont,'Segoe UI',Arial,sans-serif;color:${C.muted};padding:6px 0;">Nothing to show.</div>`;
  }
  const th = headers.map((h, i) =>
    `<th align="${aligns[i] ?? "left"}" style="font:600 10px/1.3 -apple-system,BlinkMacSystemFont,'Segoe UI',Arial,sans-serif;color:${C.faint};text-transform:uppercase;letter-spacing:.5px;padding:0 8px 6px 0;border-bottom:1px solid ${C.line};">${esc(h)}</th>`).join("");
  const tr = rows.map((r, ri) =>
    `<tr style="background:${ri % 2 ? "#fafbfc" : C.card};">` +
    r.map((c, i) =>
      `<td align="${aligns[i] ?? "left"}" style="font:400 13px/1.5 -apple-system,BlinkMacSystemFont,'Segoe UI',Arial,sans-serif;color:${C.ink};padding:7px 8px 7px 0;border-bottom:1px solid ${C.line};">${c}</td>`).join("") +
    `</tr>`).join("");
  return `<table role="presentation" width="100%" cellpadding="0" cellspacing="0"><tr>${th}</tr>${tr}</table>`;
}

function callout(text: string) {
  return `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 18px;background:${C.warnBg};border:1px solid #fed7aa;border-radius:8px;">
    <tr><td style="padding:11px 14px;font:400 12px/1.55 -apple-system,BlinkMacSystemFont,'Segoe UI',Arial,sans-serif;color:${C.warn};">${text}</td></tr>
  </table>`;
}

function shell(kindLabel: string, dateLabel: string, strap: string, inner: string, footer: string) {
  return `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light only"><meta name="supported-color-schemes" content="light only">
<title>${esc(kindLabel)}</title></head>
<body style="margin:0;padding:0;background:${C.page};">
<div style="display:none;max-height:0;overflow:hidden;opacity:0;">${esc(strap)}</div>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:${C.page};padding:24px 12px;">
<tr><td align="center">
<table role="presentation" width="600" cellpadding="0" cellspacing="0" style="width:600px;max-width:100%;">
  <tr><td style="background:${C.headBg};border-radius:8px 8px 0 0;padding:18px 20px;">
    <div style="font:700 17px/1.25 -apple-system,BlinkMacSystemFont,'Segoe UI',Arial,sans-serif;color:#ffffff;">${esc(kindLabel)}</div>
    <div style="font:400 12px/1.5 -apple-system,BlinkMacSystemFont,'Segoe UI',Arial,sans-serif;color:#9aa4b5;padding-top:3px;">${esc(dateLabel)} &nbsp;·&nbsp; ${esc(strap)}</div>
  </td></tr>
  <tr><td style="background:${C.page};padding:18px 0 0;">${inner}</td></tr>
  <tr><td style="padding:4px 4px 24px;font:400 11px/1.6 -apple-system,BlinkMacSystemFont,'Segoe UI',Arial,sans-serif;color:${C.faint};">${footer}</td></tr>
</table>
</td></tr></table></body></html>`;
}

// ---------- the three digests ----------
function renderMorning(d: any) {
  const y = d.yesterday ?? {}, w = d.week_to_date ?? {};
  const offers = d.chase?.aging_offers ?? [];
  const unbooked = d.chase?.unbooked_requests ?? [];
  const awaiting = d.chase?.awaiting_feedback ?? [];
  const cold = d.cold_roles ?? [];
  const chaseTotal = offers.length + unbooked.length + awaiting.length;

  let inner = statRow([
    stat("Offers aging", offers.length),
    stat("To book in", unbooked.length),
    stat("Awaiting feedback", awaiting.length),
    stat("Cold roles", cold.length),
  ]);

  inner += section("Aging offers", table(
    ["Candidate", "Role", "Consultant", "Days"],
    offers.slice(0, 8).map((o: any) => [
      esc(o.candidate ?? o.candidate_name ?? "—"), esc(o.job ?? o.job_title ?? "—"),
      esc(o.consultant ?? "—"), `<b>${esc(o.days ?? o.days_waiting ?? o.days_since ?? "—")}</b>`]),
    ["left", "left", "left", "right"]),
    "An offer sitting unanswered is the most expensive thing on any desk.");

  inner += section("Interview requests never booked", table(
    ["Candidate", "Role", "Consultant", "Days"],
    unbooked.slice(0, 8).map((r: any) => [
      esc(r.candidate ?? "—"), esc(r.job ?? "—"), esc(r.consultant ?? "—"),
      `<b>${esc(r.days_waiting ?? "—")}</b>`]),
    ["left", "left", "left", "right"]));

  inner += section("Interviewed, nothing logged since", table(
    ["Candidate", "Role", "Consultant", "Days"],
    awaiting.slice(0, 8).map((r: any) => [
      esc(r.candidate ?? "—"), esc(r.job ?? "—"), esc(r.consultant ?? "—"),
      `<b>${esc(r.days_since ?? "—")}</b>`]),
    ["left", "left", "left", "right"]),
    "Silence in the system, not proof feedback was never given — worth a check, not a telling-off.");

  inner += section(`Previous working day — ${ddmmyyyy(d.previous_working_day)}`, table(
    ["CV sent", "IV requests", "1st interviews", "Placed", "Calls", "BD", "Client"],
    [[y.cv_sent ?? 0, y.interview_request ?? 0, y.first_interview ?? 0, y.placed ?? 0,
      y.calls ?? 0, y.bd_calls ?? 0, y.client_calls ?? 0]],
    ["right", "right", "right", "right", "right", "right", "right"]));

  inner += section("Week to date", table(
    ["CV sent", "IV requests", "1st interviews"],
    [[w.cv_sent ?? 0, w.interview_request ?? 0, w.first_interview ?? 0]],
    ["right", "right", "right"]));

  return {
    subject: `Octagon Morning Brief — ${dayLabel(d.for_date)} · ${chaseTotal} to chase`,
    strap: `${offers.length} offers aging, ${cold.length} cold roles`,
    kindLabel: "Octagon Morning Brief",
    inner,
  };
}

function renderEvening(d: any) {
  const t = d.totals ?? {}, c = d.calls ?? {};
  const per = d.by_consultant ?? [];
  const placed = d.placements ?? [];
  const newJobs = d.new_jobs ?? [];

  let inner = statRow([
    stat("CV sent", t.cv_sent ?? 0),
    stat("IV requests", t.interview_request ?? 0),
    stat("1st interviews", t.first_interview ?? 0),
    stat("Placed", t.placed ?? 0),
  ]);

  if (placed.length) {
    inner += section("Placements today", table(
      ["Role", "Consultant", "Deal value"],
      placed.map((p: any) => [esc(p.candidate_job ?? "—"), esc(p.consultant ?? "—"),
        p.deal_value == null ? `<span style="color:${C.warn};">no Won deal</span>` : `<b>${gbp(p.deal_value)}</b>`]),
      ["left", "left", "right"]),
      "A placement bills only once the deal is moved to Won with a value entered.");
  }

  inner += section("By consultant", table(
    ["Consultant", "CV", "IV req", "1st", "Placed"],
    per.map((p: any) => [esc(p.name), p.cv_sent, p.interview_request, p.first_interview, p.placed]),
    ["left", "right", "right", "right", "right"]));

  inner += section("Calls", table(
    ["Total", "Connected", "Connect rate", "BD", "Client", "Tagged"],
    [[c.total ?? 0, c.connected ?? 0, `${c.connect_rate ?? 0}%`, c.bd ?? 0, c.client ?? 0,
      `${c.tagged_pct ?? 0}%`]],
    ["right", "right", "right", "right", "right", "right"]));

  if ((c.tagged_pct ?? 0) < 30) {
    inner += callout(`Only <b>${esc(c.tagged_pct ?? 0)}%</b> of today's calls carry a category, so the BD and client figures above are a floor rather than an actual. A zero there usually means untagged calls, not no activity.`);
  }

  if (newJobs.length) {
    inner += section("New jobs today", table(
      ["Role", "Owner", "Job order form"],
      newJobs.map((j: any) => [esc(j.title ?? "—"), esc(j.owner ?? "—"),
        j.job_order_form ? `<span style="color:${C.good};">logged</span>` : `<span style="color:${C.warn};">not logged</span>`]),
      ["left", "left", "right"]),
      "A form not logged does not prove the qualifying call did not happen.");
  }

  return {
    subject: `Octagon Day End — ${dayLabel(d.for_date)} · ${t.cv_sent ?? 0} CVs, ${t.first_interview ?? 0} interviews${(t.placed ?? 0) ? `, ${t.placed} placed` : ""}`,
    strap: `${c.total ?? 0} calls, ${c.connect_rate ?? 0}% connected`,
    kindLabel: "Octagon Day End",
    inner,
  };
}

function renderWeekly(d: any) {
  const cold = d.cold_roles ?? [];
  const nj = d.new_jobs ?? {};
  const njt = nj.totals ?? {};
  const f = d.last_week?.funnel ?? {};
  const ft = f.totals ?? {};
  const kpis = d.kpis?.consultants ?? [];

  let inner = statRow([
    stat("Cold roles", cold.length, "7+ days quiet"),
    stat("New jobs", njt.new_jobs ?? 0, "last week"),
    stat("Missing form", njt.missing_job_order_form ?? 0),
    stat("Placed", ft.placed ?? 0, "last week"),
  ]);

  inner += section(`Last week's funnel — ${ddmmyyyy(d.last_week?.from)} to ${ddmmyyyy(d.last_week?.to)}`, table(
    ["CV sent", "IV req", "1st", "2nd", "3rd", "Offered", "Placed"],
    [[ft.cv_sent ?? 0, ft.interview_request ?? 0, ft.first_interview ?? 0, ft.second_interview ?? 0,
      ft.third_interview ?? 0, ft.offered ?? 0, ft.placed ?? 0]],
    ["right", "right", "right", "right", "right", "right", "right"]));

  inner += section("Job order forms", table(
    ["New jobs", "With form", "Missing", "Completion"],
    [[njt.new_jobs ?? 0, njt.with_job_order_form ?? 0, njt.missing_job_order_form ?? 0,
      `${njt.form_completion_pct ?? 0}%`]],
    ["right", "right", "right", "right"]),
    "Missing means the note was never logged, not that the qualifying call never happened.");

  inner += section("Cold open roles", table(
    ["Role", "Client", "Owner", "Days quiet"],
    cold.slice(0, 12).map((j: any) => [esc(j.title ?? j.job ?? "—"), esc(j.client ?? "—"),
      esc(j.consultant ?? j.owner ?? "—"), `<b>${esc(j.days_since_activity ?? j.days ?? "—")}</b>`]),
    ["left", "left", "left", "right"]));

  if (kpis.length) {
    inner += section("This week vs target", table(
      ["Consultant", "CV sent", "IV req", "1st int"],
      kpis.slice(0, 15).map((k: any) => [esc(k.name),
        `${k.cv_sent?.actual ?? 0} / ${k.cv_sent?.target ?? "—"}`,
        `${k.interview_request?.actual ?? 0} / ${k.interview_request?.target ?? "—"}`,
        `${k.first_interview?.actual ?? 0} / ${k.first_interview?.target ?? "—"}`]),
      ["left", "right", "right", "right"]),
      "BD and client calls are omitted here: only ~10% of calls are categorised, so those targets are not measurable.");
  }

  return {
    subject: `Octagon Week Ahead — ${dayLabel(d.week_starting)} · ${cold.length} cold roles, ${njt.missing_job_order_form ?? 0} missing a form`,
    strap: `${ft.placed ?? 0} placed last week`,
    kindLabel: "Octagon Week Ahead",
    inner,
  };
}

// ---------- entry ----------
Deno.serve(async (req) => {
  const url = new URL(req.url);
  const kind = (url.searchParams.get("kind") ?? "morning").toLowerCase();
  const dry = url.searchParams.get("dry") === "1";

  const fn = { morning: "digest_morning", evening: "digest_evening", weekly: "digest_weekly" }[kind];
  if (!fn) return Response.json({ error: `unknown kind '${kind}'` }, { status: 400 });

  const { data, error } = await db.rpc(fn);
  if (error) return Response.json({ error: error.message }, { status: 500 });

  const r = kind === "morning" ? renderMorning(data)
    : kind === "evening" ? renderEvening(data)
    : renderWeekly(data);

  // Sync health rides along in the footer so a stale figure is never presented as fresh.
  const health = (data as any)?.health;
  const ok = health?.overall === "ok";
  const healthLine = ok
    ? "Sync healthy."
    : `<span style="color:${C.warn};"><b>Sync is not healthy</b> — figures may be stale. Affected: ${esc((health?.entities ?? []).filter((e: any) => e.status !== "ok").map((e: any) => e.entity).join(", ") || "unknown")}.</span>`;

  const footer = `${healthLine} Generated ${ddmmyyyy(data.generated_at)} from RecruitCRM via the Octagon metrics layer.<br>
    Funnel counts distinct candidate-job pairs credited to whoever moved the stage. BD and client call
    figures count only categorised Devyce calls and under-report.`;

  const html = shell(r.kindLabel, ddmmyyyy(data.for_date ?? data.week_starting), r.strap, r.inner, footer);

  const { data: row } = await db.from("app_settings").select("value").eq("key", "digest_to_email").maybeSingle();
  const to = (row?.value ?? "").trim();

  if (dry) return new Response(html, { headers: { "content-type": "text/html; charset=utf-8" } });
  if (!to) return Response.json({ kind, sent: false, reason: "digest_to_email not set in app_settings" });
  if (!RESEND_KEY) return Response.json({ kind, sent: false, reason: "RESEND_API_KEY not set", subject: r.subject });

  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${RESEND_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({ from: MAIL_FROM, to: [to], subject: r.subject, html }),
  });
  const body = await res.text();
  return Response.json({ kind, sent: res.ok, to, subject: r.subject, status: res.status, detail: res.ok ? undefined : body.slice(0, 300) });
});
