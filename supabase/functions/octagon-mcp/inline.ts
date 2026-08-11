// The dashboard as a fixed block of markdown, generated server-side and printed verbatim.
//
// Why this exists: Claude Web drops ui:// widgets for custom connectors (claude-ai-mcp#471), and
// artifacts open in a side panel. The only surface guaranteed to render inline in the conversation
// is the assistant's own message. So the server composes the exact characters and the model is
// told to output them unchanged — that keeps it deterministic (identical every time, for everyone)
// rather than a summary the model rewrites on each call.
//
// Same data, order and thresholds as the PNG and the widget, so the three cannot disagree.

export {};   // module marker so `node --check` strips types (the CJS path does not)
const gbp = (n: any) => n == null ? "—" : "£" + Math.round(Number(n)).toLocaleString("en-GB");
const num = (n: any) => n == null ? "—" : Number(n).toLocaleString("en-GB");
const dmy = (s: any) => { const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(s ?? "")); return m ? `${m[3]}/${m[2]}/${m[1]}` : String(s ?? ""); };

// Unicode blocks give a real bar chart in plain text. 10 cells keeps it readable on mobile.
function bar(value: number, max: number, cells = 10): string {
  if (!max || max <= 0) return "░".repeat(cells);
  const filled = Math.max(value > 0 ? 1 : 0, Math.round((value / max) * cells));
  return "█".repeat(Math.min(cells, filled)) + "░".repeat(Math.max(0, cells - filled));
}

export function dashboardMarkdown(d: any): string {
  const v = d.viewer ?? {}, k = d.kpis ?? {};
  const mine = !!(v.name && !v.is_admin);
  const health = (d.health ?? {}).overall === "ok"
    ? "sync healthy"
    : `⚠ SYNC ISSUE — ${((d.health?.entities ?? []).filter((e: any) => e.status !== "ok").map((e: any) => e.entity).join(", ")) || "unknown"}`;
  const L: string[] = [];

  L.push(`### ${mine ? `Your desk — ${v.name}` : "Octagon Recruitment Dashboard"}`);
  L.push(`*${health} · 2026 year to date*`);
  L.push("");

  if (mine) {
    const b = v.my_billing ?? {}, day = v.my_day ?? {}, y = v.my_2026 ?? {};
    L.push("| | | |");
    L.push("|---|---|---|");
    L.push(`| **${num(y.placed)}** placed 2026 | **${gbp(b.won_qtr)}** won this quarter | **${gbp(b.pipeline_open)}** open pipeline |`);
    L.push(`| **${num(day.active_in_play)}** active in play | **${num((day.aging_offers ?? []).length)}** aging offers | **${num(day.cold_open_roles)}** cold roles |`);
    L.push("");

    if (v.my_billing?.quarterly_target != null) {
      const gap = Number(b.quarterly_target) - Number(b.won_qtr ?? 0);
      const pct = Math.round(100 * Number(b.won_qtr ?? 0) / Number(b.quarterly_target));
      L.push(`**Billing** ${gbp(b.won_qtr)} of ${gbp(b.quarterly_target)} (${pct}%)` +
             (gap > 0 ? ` — **${gbp(gap)}** still to bill` : " — **target met**"));
      L.push("");
    }

    if (v.my_weekly) {
      L.push(`**This week vs target** — from ${dmy(v.week_start)}`);
      L.push("");
      L.push("| | | |");
      L.push("|---|---|---|");
      for (const [label, key] of [["CV sends","cv_sent"],["Interview requests","interview_request"],
           ["Interviews","first_interview"],["BD calls","bd_calls"],["Client calls","client_calls"]]) {
        const m = v.my_weekly[key] ?? {}, a = m.actual ?? 0, t = m.target;
        const behind = t != null && a < t;
        L.push(`| ${label} | \`${bar(a, t ?? a)}\` | ${t != null ? `${a} / ${t}` : a}${behind ? " ⚠" : " ✓"} |`);
      }
      L.push("");
    }
  } else {
    L.push("| | | |");
    L.push("|---|---|---|");
    L.push(`| **${num(k.placed_2026)}** placed 2026 | **${num(k.open_jobs)}** open jobs | **${gbp(k.open_pipeline)}** open pipeline |`);
    L.push(`| **${gbp(k.won)}** won all-time | **${num(k.clients)}** clients | **${num(k.candidates_in_pipeline)}** in pipeline |`);
    L.push("");
  }

  const f = mine ? (v.my_2026 ?? {}) : (d.funnel ?? {});
  const stages: [string, string][] = mine
    ? [["Shortlist","shortlist"],["CV Sent","cv_sent"],["Interview Request","interview_request"],
       ["1st Interview","first_interview"],["Offered","offered"],["Placed","placed"]]
    : [["Shortlist","shortlist"],["CV Sent","cv_sent"],["Interview Request","interview_request"],
       ["1st Interview","first_interview"],["2nd Interview","second_interview"],
       ["3rd Interview","third_interview"],["Offered","offered"],["Placed","placed"]];
  const max = Math.max(1, ...stages.map(s => Number(f[s[1]] ?? 0)));
  L.push(`**${mine ? "Your" : "Firm"} 2026 funnel**`);
  L.push("");
  L.push("| | | |");
  L.push("|---|---|---|");
  for (const [label, key] of stages) {
    const val = Number(f[key] ?? 0);
    L.push(`| ${label} | \`${bar(val, max)}\` | ${num(val)} |`);
  }
  L.push("");

  if (!mine && Array.isArray(d.pipeline) && d.pipeline.length) {
    L.push("**Deal pipeline**");
    L.push("");
    L.push("| Stage | Deals | Value |");
    L.push("|---|---:|---:|");
    for (const p of d.pipeline.slice(0, 6)) L.push(`| ${p.stage} | ${num(p.deals)} | ${gbp(p.value)} |`);
    L.push("");
  }

  L.push(`*Firm 2026: ${num(k.cv_2026)} CV sent · ${num(k.placed_2026)} placed · ${num(k.open_jobs)} open jobs · ${gbp(k.open_pipeline)} pipeline*`);
  return L.join("\n");
}
