// eow.ts — the end-of-week team email, shared by the eow_email tool (Outlook draft) and the
// Friday digest-email send (Resend), so the two can never drift apart.
//
// loadEow() gathers the figures; renderEowHtml() builds the email. Candidate names appear in the
// Offers table: the email is internal to the team and must never go to a client.

// deno-lint-ignore no-explicit-any
type Any = any;

export type ContactLookup = (jobSlug: string) => Promise<string | null>;

export const EOW_THRESHOLDS = "10+ CVs sent, 4+ interview requests, 10+ BD calls, any offer";

// Gathers the week's report, shout-outs and plan rows. p_to is end-exclusive.
// contactName fills the hiring contact for each new job (not in the mirror); without it the
// Contact column is left blank rather than guessed.
export async function loadEow(db: Any, p: { p_from: string; p_to: string }, contactName?: ContactLookup) {
  const { data: rep, error } = await db.rpc("eow_report", p);
  if (error) return { error: error.message as string };
  for (const j of rep.jobs ?? []) {
    j.contact = contactName && j.slug ? await contactName(j.slug).catch(() => null) : null;
    delete j.slug;
  }
  const first = (n: string) => String(n ?? "").split(" ")[0];
  const people = (rep.consultants ?? []).filter((c: Any) => !c.left);
  const named = (rows: Any[], k: string) => rows.sort((a, b) => b[k] - a[k]).map((c) => `${first(c.name)} (${c[k]})`);
  const shout = {
    cv_sent: named(people.filter((c: Any) => c.cv_sent >= 10), "cv_sent"),
    interview_requests: named(people.filter((c: Any) => c.interview_requests >= 4), "interview_requests"),
    bd_calls: named(people.filter((c: Any) => c.bd_calls >= 10), "bd_calls"),
    offers: people.filter((c: Any) => c.offers > 0).sort((a: Any, b: Any) => b.offers - a.offers)
      .map((c: Any) => c.offers > 1 ? `${first(c.name)} (${c.offers})` : first(c.name)),
  };
  const { data: wplan } = await db.rpc("weekly_plan");
  const planRows = ((wplan?.consultants ?? []) as Any[]).filter((x) => people.some((c: Any) => c.name === x.consultant));
  return { rep, shout, planRows };
}

export const dmy = (s: Any) => {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(s ?? ""));
  return m ? `${m[3]}/${m[2]}/${m[1]}` : String(s ?? "");
};

export const eowSubject = (from: string) => `End of week: ${dmy(from)}`;

export function renderEowHtml(
  data: { rep: Any; shout: Any; planRows: Any[] },
  args: { greeting?: string; intro?: string; closing?: string; comments?: Record<string, string>; preface?: string } = {},
) {
  const { rep, shout, planRows } = data;
  const h = (s: Any) => String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]!));
  const para = (s: Any) => String(s ?? "").trim() ? `<p>${h(s).replace(/\n/g, "<br>")}</p>` : "";
  const list = (xs: string[]) => xs.length <= 1 ? (xs[0] ?? "") : `${xs.slice(0, -1).join(", ")} and ${xs[xs.length - 1]}`;
  const c = args.comments ?? {};
  const t = rep.totals ?? {};
  const shoutLine = (label: string, xs: string[], comment: Any) => xs.length ? `<li><b>${label}:</b> ${h(list(xs))}.${String(comment ?? "").trim() ? " " + h(comment) : ""}</li>` : "";
  const TH = 'style="background:#0b4479;color:#fff;padding:6px 10px;border:1px solid #d9d9d9;text-align:left"';
  const TD = (i: number) => `style="padding:6px 10px;border:1px solid #d9d9d9;${i % 2 ? "background:#f1eee8;" : ""}"`;
  const table = (head: string[], rows: Any[][]) => `<table style="border-collapse:collapse;font-family:Calibri,Arial,sans-serif;font-size:14px;margin:8px 0 18px">`
    + `<tr>${head.map((x) => `<th ${TH}>${h(x)}</th>`).join("")}</tr>`
    + rows.map((r, i) => `<tr>${r.map((x) => `<td ${TD(i)}>${h(x)}</td>`).join("")}</tr>`).join("") + `</table>`;
  const team = table(["Team member", "Jobs added", "Candidates assigned", "CVs sent", "IV requests", "Interviews", "Offers", "BD calls"],
    [...(rep.consultants ?? []).map((r: Any) => [r.left ? `${r.name} (left)` : r.name, r.jobs_added, r.candidates_assigned, r.cv_sent, r.interview_requests, r.interviews, r.offers, r.bd_calls]),
     ["Total", t.jobs_added, t.candidates_assigned, t.cv_sent, t.interview_requests, t.interviews, t.offers, t.bd_calls]]);
  const offersT = (rep.offers ?? []).length ? table(["Candidate", "Company", "Job", "Current stage", "Stage date", "Offered by"],
    rep.offers.map((o: Any) => [o.candidate, o.company, o.job, o.current_stage, dmy(o.current_stage_date), o.offered_by])) : "<p>No offers this week.</p>";
  const jobsT = (rep.jobs ?? []).length ? table(["Job", "Company", "Contact", "Status", "Date added", "Owner"],
    rep.jobs.map((j: Any) => [j.title, j.company, j.contact ?? "", j.status, dmy(j.date_added), j.owner])) : "<p>No new jobs this week.</p>";
  // Actuals against each consultant's plan (worked back from billing), with the gap.
  const gap = (a: Any, p: Any) => { const d = Number(a ?? 0) - Number(p ?? 0); return d >= 0 ? `${a} of ${p}` : `${a} of ${p} (${d})`; };
  const gbp = (n: Any) => `£${Number(n ?? 0).toLocaleString("en-GB")}`;
  const planT = planRows.length ? table(["Team member", "CVs sent", "IV requests", "Interviews", "Step to work on", "Quarter so far"],
    planRows.map((x: Any) => [x.consultant, gap(x.this_week?.cv_sent, x.plan?.cv_sent), gap(x.this_week?.interview_request, x.plan?.interview_request),
      gap(x.this_week?.first_interview, x.plan?.first_interview), x.ratio_to_work_on ?? "",
      x.quarter_position?.target == null ? `${gbp(x.quarter_position?.won_by_close_date)} (no target set)`
        : `${gbp(x.quarter_position?.won_by_close_date)} of ${gbp(x.quarter_position.target)}`])) : "";
  return `<div style="font-family:Calibri,Arial,sans-serif;font-size:15px">`
    + (args.preface ?? "")
    + `<p>${h(args.greeting ?? "Hi all,")}</p>` + para(args.intro)
    + `<p>Here's how the week shaped up:</p><ul>`
    + `<li>📄 ${t.cv_sent ?? 0} CVs sent to clients</li><li>📞 ${t.interview_requests ?? 0} interview requests secured</li>`
    + `<li>☎️ ${t.bd_calls ?? 0} BD calls made</li><li>🎉 ${t.offers ?? 0} offer${t.offers === 1 ? "" : "s"} landed</li></ul>`
    + `<p>Shout-outs:</p><ul>`
    + shoutLine("10+ CVs sent", shout.cv_sent, c.cv_sent) + shoutLine("4+ interview requests", shout.interview_requests, c.interview_requests)
    + shoutLine("10+ BD calls", shout.bd_calls, c.bd_calls) + shoutLine("Offers landed: congrats to", shout.offers, c.offers) + `</ul>`
    + para(args.closing)
    + `<p><b>Team</b></p>${team}`
    + (planT ? `<p><b>Against plan</b> (each person's weekly plan, worked back from their billing target)</p>${planT}` : "")
    + `<p><b>Offers</b></p>${offersT}<p><b>Jobs</b></p>${jobsT}</div>`;
}
