// recruitcrm-probe — TEMPORARY, read-only shape probe.
//
// Purpose: verify the RecruitCRM token works and discover the REAL payload
// shapes (the brief's open question) WITHOUT exposing candidate PII and without
// anyone pasting the token around. It reads the token from the environment
// secret RECRUITCRM_API_TOKEN, calls a few list endpoints with a tiny page,
// and returns ONLY the field names + value *types* of the first record — never
// the values themselves. Delete this function once the shapes are captured.

export {};   // marks this as a module so `node --check` strips types (CJS path does not)
const BASE = "https://api.recruitcrm.io/v1";
// Probing where the FEE lives: the placement record has no fee column, so it is either on the
// linked deal or in custom_fields. Custom-field NAMES are configuration, not data — safe to return.
const ENDPOINTS = ["placements", "deals", "jobs"];

// Field names only from a custom_fields array — never the values.
function customFieldNames(rec: any): string[] | null {
  const cf = rec?.custom_fields;
  if (!Array.isArray(cf)) return null;
  return cf.map((f: any) =>
    typeof f === "object" && f !== null
      ? String(f.field_name ?? f.name ?? f.label ?? f.key ?? Object.keys(f).join("|"))
      : String(f)
  );
}

// Map a record to { field: "type" } — redacts every actual value.
function shapeOf(rec: unknown): Record<string, string> {
  if (rec === null || typeof rec !== "object") return { _value: typeof rec };
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(rec as Record<string, unknown>)) {
    out[k] = v === null
      ? "null"
      : Array.isArray(v)
      ? "array"
      : typeof v === "object"
      ? "object"
      : typeof v; // string | number | boolean
  }
  return out;
}

// Capability probe: which HTTP methods does an endpoint accept? OPTIONS has no side effects, so
// this is safe to run against the live CRM — unlike POSTing a deliberately-invalid body, which can
// create junk records in the system of record.
async function methodsFor(token: string, path: string) {
  try {
    const res = await fetch(`${BASE}/${path}`, { method: "OPTIONS", headers: { Authorization: `Bearer ${token}`, Accept: "application/json" } });
    const h: Record<string, string> = {};
    res.headers.forEach((v, k) => { if (/allow|access-control-allow-methods/i.test(k)) h[k] = v; });
    return { status: res.status, headers: Object.keys(h).length ? h : null };
  } catch (e) { return { error: String(e) }; }
}

// Read-only GET passthrough, admin-only (verify_jwt=true). Invoices taught the lesson: building
// tools for an unused feature is wasted work, so check whether data exists before writing code.
// Returns counts and field NAMES, never values.
async function peek(token: string, path: string) {
  try {
    const res = await fetch(`${BASE}/${path}`, { headers: { Authorization: `Bearer ${token}`, Accept: "application/json" } });
    const text = await res.text();
    let json: any = null; try { json = JSON.parse(text); } catch {}
    const inner = json?.data ?? json;
    const rows = Array.isArray(inner) ? inner : (inner?.records ?? (Array.isArray(json) ? json : null));
    return {
      status: res.status,
      rows: Array.isArray(rows) ? rows.length : null,
      total: json?.total ?? null,
      top_level_keys: json && typeof json === "object" && !Array.isArray(json) ? Object.keys(json).slice(0, 12) : null,
      first_record_fields: Array.isArray(rows) && rows[0] && typeof rows[0] === "object" ? Object.keys(rows[0]).slice(0, 30) : null,
      body_if_empty: Array.isArray(rows) && rows.length === 0 ? text.slice(0, 160) : undefined,
      // For a single record, return only boolean/number fields — enough to check a flag's real
      // value without exposing any personal data.
      scalar_flags: (!Array.isArray(rows) && inner && typeof inner === "object")
        ? Object.fromEntries(Object.entries(inner).filter(([, v]) => typeof v === "boolean" || typeof v === "number"))
        : undefined,
      // Opt-out flags specifically, whatever their type — a string "0" is truthy in JS and would
      // silently block every recipient, so the exact value matters.
      optout_fields: (!Array.isArray(rows) && inner && typeof inner === "object")
        ? Object.fromEntries(Object.entries(inner)
            .filter(([k]) => /opt|unsubscrib/i.test(k))
            .map(([k, v]) => [k, { value: v, type: typeof v }]))
        : undefined,
    };
  } catch (e) { return { error: String(e) }; }
}

// RecruitCRM's own target report, with values. The one exception to "never return values": target
// configuration is not candidate data (names, dates, KPI names, numbers, assignee user ids), and the
// point is to compare it against weekly_targets / billing_targets (ROADMAP Tier 1, "Targets").
// Assignees are reduced to id and name - staff, not candidates - and nothing else is passed through.
async function targetReport(token: string) {
  const res = await fetch(`${BASE}/target-report/get`, { headers: { Authorization: `Bearer ${token}`, Accept: "application/json" } });
  const text = await res.text();
  let json: any = null; try { json = JSON.parse(text); } catch {}
  if (!res.ok || !json) return { status: res.status, error: text.slice(0, 200) };
  const rows = Array.isArray(json?.data) ? json.data : [];
  const person = (a: any) => (a && typeof a === "object")
    ? { id: a.id ?? a.Id ?? a.user_id ?? a.UserId ?? null, name: a.name ?? a.Name ?? ([a.first_name, a.last_name].filter(Boolean).join(" ") || null) }
    : { id: a, name: null };
  return {
    status: res.status, total: json.total ?? rows.length,
    targets: rows.map((t: any) => ({
      id: t.TargetId, name: t.TargetName, created_on: t.CreatedOn, created_by: t.CreatedBy,
      start: t.StartDate, end: t.EndDate, frequency: t.Frequency, assignee_type: t.TypeOfAssignees,
      assignees: Array.isArray(t.Assignees) ? t.Assignees.map(person) : t.Assignees,
      kpis: t.TargetKPIs,
    })),
  };
}

Deno.serve(async (req) => {
  {
    const probeUrl = new URL(req.url);
    if (probeUrl.searchParams.get("call_notes_probe")) {
      const tk = Deno.env.get("RECRUIT_CRM_API_TOKEN") ?? Deno.env.get("RECRUITCRM_API_TOKEN") ?? "";
      const n = Number(probeUrl.searchParams.get("sample") ?? "25") || 25;
      return Response.json(await callNotesProbe(tk, n));
    }
    if (probeUrl.searchParams.get("call_notes_structure")) {
      const tk = Deno.env.get("RECRUIT_CRM_API_TOKEN") ?? Deno.env.get("RECRUITCRM_API_TOKEN") ?? "";
      const n = Number(probeUrl.searchParams.get("sample") ?? "50") || 50;
      return Response.json(await callNotesStructure(tk, n));
    }
    if (probeUrl.searchParams.get("target_report")) {
      const tk = Deno.env.get("RECRUIT_CRM_API_TOKEN") ?? Deno.env.get("RECRUITCRM_API_TOKEN") ?? "";
      return Response.json(await targetReport(tk));
    }
    const getPath = probeUrl.searchParams.get("get_for");
    if (getPath) {
      const tk = Deno.env.get("RECRUIT_CRM_API_TOKEN") ?? Deno.env.get("RECRUITCRM_API_TOKEN") ?? "";
      return Response.json({ path: getPath, ...(await peek(tk, getPath)) });
    }
    const optPath = probeUrl.searchParams.get("options_for");
    if (optPath) {
      const tk = Deno.env.get("RECRUIT_CRM_API_TOKEN") ?? Deno.env.get("RECRUITCRM_API_TOKEN") ?? "";
      return Response.json({ path: optPath, ...(await methodsFor(tk, optPath)) });
    }
  }
  return await originalHandler();
});

async function originalHandler(): Promise<Response> {
  // The project secret is RECRUIT_CRM_API_TOKEN; keep the old name as a fallback.
  const token = Deno.env.get("RECRUIT_CRM_API_TOKEN") ?? Deno.env.get("RECRUITCRM_API_TOKEN");
  if (!token) {
    return Response.json({ error: "RECRUITCRM_API_TOKEN not set" }, { status: 500 });
  }

  const report: Record<string, unknown> = {};
  for (const ep of ENDPOINTS) {
    try {
      const res = await fetch(`${BASE}/${ep}?page=1`, {
        headers: { Authorization: `Bearer ${token}`, Accept: "application/json" },
      });
      const bodyText = await res.text();
      let json: any = null;
      try { json = JSON.parse(bodyText); } catch { /* non-JSON */ }

      // RecruitCRM list responses are typically { data: [...], current_page, ... }
      const firstRecord = json?.data?.[0] ?? json?.[0] ?? null;

      report[ep] = {
        status: res.status,
        top_level_keys: json && typeof json === "object" ? Object.keys(json) : null,
        record_count_this_page: Array.isArray(json?.data) ? json.data.length : null,
        first_record_shape: firstRecord ? shapeOf(firstRecord) : null,
        // Names across the whole page, not just record 1 — custom fields are sparsely populated.
        custom_field_names: Array.isArray(json?.data)
          ? Array.from(new Set(json.data.flatMap((r: any) => customFieldNames(r) ?? []))).sort()
          : null,
        total: json?.total ?? null,
      };
    } catch (e) {
      report[ep] = { error: String(e) };
    }
  }

  return Response.json({ probed_at: "on-demand", base: BASE, endpoints: report });
}

// ---- call_notes probe (Devyce AI summaries) --------------------------------------------------
// Question: do Devyce AI call summaries land in RecruitCRM call logs, which field, what format,
// and can call logs be filtered to one candidate/contact?
// Returns ONLY field names, lengths, counts and boolean format flags. Never a value, never a slug,
// never a phone number, never a name. Text-ish fields are measured, not returned.

const TEXT_FIELD_RE = /note|summary|desc|transcript|comment|remark|detail|(^|_)ai(_|$)/i;

function median(xs: number[]): number | null {
  if (!xs.length) return null;
  const s = [...xs].sort((a, b) => a - b);
  const m = Math.floor(s.length / 2);
  return s.length % 2 ? s[m] : Math.round((s[m - 1] + s[m]) / 2);
}

// Format flags only: shape of the text, not what it says.
function formatFlags(t: string) {
  const lines = t.split(/\r?\n/);
  return {
    has_html: /<\/?[a-z][^>]*>/i.test(t),
    has_newlines: lines.length > 1,
    line_count: lines.length,
    bullet_lines: lines.filter((l) => /^\s*([-*•]|\d+[.)])\s+/.test(l)).length,
    heading_like_lines: lines.filter((l) => /^\s*[A-Z][A-Za-z ]{1,40}:\s*$/.test(l) || /^\s*#{1,4}\s/.test(l)).length,
    looks_json: /^\s*[\[{]/.test(t),
    mentions_devyce: /devyce/i.test(t),          // boolean only: is the source marked?
    has_speaker_labels: /^\s*(agent|caller|customer|speaker\s*\d|consultant|candidate)\s*:/im.test(t), // transcript vs summary
  };
}

type Agg = {
  present_in: number; non_empty: number; types: Record<string, number>;
  lengths: number[]; html: number; multiline: number; bullets: number; headings: number;
  json: number; devyce: number; speaker_labels: number;
};

async function callNotesProbe(token: string, sample: number) {
  const h = { Authorization: `Bearer ${token}`, Accept: "application/json" };
  const limit = Math.min(Math.max(sample, 5), 50);

  // 1. Most recent call logs (same ordering the incremental sync uses).
  const res = await fetch(`${BASE}/call-logs?page=1&limit=${limit}&sort_by=updatedon&sort_order=desc`, { headers: h });
  const text = await res.text();
  let json: any = null; try { json = JSON.parse(text); } catch {}
  const rows: any[] = Array.isArray(json?.data) ? json.data : [];

  const allKeys = new Set<string>();
  const agg: Record<string, Agg> = {};
  const byType: Record<string, { calls: number; with_notes: number }> = {};
  let withAnyText = 0;

  for (const r of rows) {
    Object.keys(r ?? {}).forEach((k) => allKeys.add(k));
    const rtype = String(r?.related_to_type ?? "unknown");
    byType[rtype] ??= { calls: 0, with_notes: 0 };
    byType[rtype].calls++;
    let anyText = false;

    for (const [k, v] of Object.entries(r ?? {})) {
      if (!TEXT_FIELD_RE.test(k)) continue;
      const a = (agg[k] ??= { present_in: 0, non_empty: 0, types: {}, lengths: [], html: 0, multiline: 0, bullets: 0, headings: 0, json: 0, devyce: 0, speaker_labels: 0 });
      a.present_in++;
      const t = v === null ? "null" : Array.isArray(v) ? "array" : typeof v;
      a.types[t] = (a.types[t] ?? 0) + 1;
      const s = typeof v === "string" ? v : (v && typeof v === "object") ? JSON.stringify(v) : "";
      if (s.trim().length === 0) continue;
      a.non_empty++; anyText = true;
      a.lengths.push(s.length);
      const f = formatFlags(s);
      if (f.has_html) a.html++;
      if (f.has_newlines) a.multiline++;
      if (f.bullet_lines > 0) a.bullets++;
      if (f.heading_like_lines > 0) a.headings++;
      if (f.looks_json) a.json++;
      if (f.mentions_devyce) a.devyce++;
      if (f.has_speaker_labels) a.speaker_labels++;
    }
    if (anyText) { withAnyText++; byType[rtype].with_notes++; }
  }

  const text_fields = Object.fromEntries(Object.entries(agg).map(([k, a]) => [k, {
    present_in: a.present_in, non_empty: a.non_empty, value_types: a.types,
    length: { min: a.lengths.length ? Math.min(...a.lengths) : null, median: median(a.lengths), max: a.lengths.length ? Math.max(...a.lengths) : null },
    records_with: { html: a.html, multiline: a.multiline, bullets: a.bullets, headings: a.headings, json: a.json, devyce_marker: a.devyce, speaker_labels: a.speaker_labels },
  }]));

  // 2. Filter test: can call logs be narrowed to ONE candidate? Uses a slug from the sample
  //    internally; the slug is never returned. Reports status + whether results all match.
  const cand = rows.find((r) => r?.related_to_type === "candidate" && r?.related_to);
  const filter_tests: Record<string, unknown> = {};
  if (cand) {
    const slug = encodeURIComponent(String(cand.related_to));
    const tries: Record<string, string> = {
      search_endpoint: `/call-logs/search?related_to=${slug}&related_to_type=candidate`,
      list_param: `/call-logs?related_to=${slug}&related_to_type=candidate&limit=50`,
    };
    for (const [label, path] of Object.entries(tries)) {
      try {
        const fr = await fetch(`${BASE}${path}`, { headers: h });
        const ft = await fr.text();
        let fj: any = null; try { fj = JSON.parse(ft); } catch {}
        const inner = fj?.data ?? fj;
        const frows: any[] = Array.isArray(inner) ? inner : (inner?.records ?? []);
        const matching = frows.filter((x) => String(x?.related_to) === String(cand.related_to)).length;
        filter_tests[label] = {
          status: fr.status, rows: frows.length, rows_matching_target: matching,
          filter_honoured: frows.length > 0 && matching === frows.length,
          paginated: Boolean(fj?.next_page_url), top_level_keys: fj && typeof fj === "object" && !Array.isArray(fj) ? Object.keys(fj).slice(0, 12) : null,
        };
      } catch (e) { filter_tests[label] = { error: String(e) }; }
    }
  } else {
    filter_tests.skipped = "no candidate-linked call in sample";
  }

  return {
    status: res.status,
    sampled: rows.length,
    total: json?.total ?? null,
    record_field_names: [...allKeys].sort(),
    calls_with_any_text: withAnyText,
    by_related_to_type: byType,
    text_fields,
    filter_tests,
    note: "Lengths, counts and format flags only. No call content, slugs, names or numbers returned.",
  };
}

// ---- call_notes structure probe (20/10/2026) ----------------------------------------------------
// Follow-up: the first probe found every call_notes value is HTML, so heading detection on raw text
// saw nothing. This strips the HTML and asks: do Devyce summaries share the same section headings?
// A heading label is returned ONLY if it is short, letters/spaces only, and appears in at least 5
// of the sampled notes AND across calls about at least 5 different people - so a name repeated on
// one person's calls can never come back. What survives is Devyce's template, not call content.
function stripToLines(html: string): string[] {
  return html
    .replace(/<\s*br\s*\/?>/gi, "\n").replace(/<\s*li[^>]*>/gi, "\n- ")
    .replace(/<\/\s*(p|div|h[1-6]|tr|ul|ol)\s*>/gi, "\n")
    .replace(/<\s*(strong|b|h[1-6])[^>]*>/gi, "\u0001").replace(/<\/\s*(strong|b|h[1-6])\s*>/gi, "\u0002")
    .replace(/<[^>]+>/g, "").replace(/&nbsp;/g, " ").replace(/&amp;/g, "&")
    .split("\n").map((l) => l.trim()).filter(Boolean);
}
function headingOf(line: string): string | null {
  const bold = /^\u0001([^\u0001\u0002]{1,40})\u0002:?$/.exec(line);
  // Only FORMATTED headings (bold / <h*> / markdown) count. A plain "Something:" line is too often a
  // person ("Sarah Jones:") to treat as structure.
  const md = /^#{1,4}\s+([A-Za-z][A-Za-z &/]{1,39})$/.exec(line.replace(/[\u0001\u0002]/g, ""));
  const raw = (bold?.[1] ?? md?.[1] ?? "").replace(/:$/, "").trim();
  return raw && /^[A-Za-z][A-Za-z &/]{0,39}$/.test(raw) ? raw.toLowerCase() : null;
}
async function callNotesStructure(token: string, sample: number) {
  const h = { Authorization: `Bearer ${token}`, Accept: "application/json" };
  const limit = Math.min(Math.max(sample, 10), 100);
  const res = await fetch(`${BASE}/call-logs?page=1&limit=${limit}&sort_by=updatedon&sort_order=desc`, { headers: h });
  let json: any = null; try { json = JSON.parse(await res.text()); } catch {}
  const rows: any[] = Array.isArray(json?.data) ? json.data : [];
  const withNotes = rows.filter((r) => String(r?.call_notes ?? "").trim());
  const notes = withNotes.map((r) => String(r.call_notes));
  const devyceRows = withNotes.filter((r) => /devyce/i.test(String(r.call_notes)));
  const devyce = devyceRows.map((r) => String(r.call_notes));
  const freq = new Map<string, number>();
  const people = new Map<string, Set<string>>();
  const perNote: number[] = [], bulletsPer: number[] = [], linesPer: number[] = [], plainLen: number[] = [];
  for (const r of devyceRows) {
    const t = String(r.call_notes);
    const who = `${r?.related_to_type ?? ""}:${r?.related_to ?? ""}`;
    const lines = stripToLines(t);
    const hs = new Set(lines.map(headingOf).filter(Boolean) as string[]);
    hs.forEach((x) => { freq.set(x, (freq.get(x) ?? 0) + 1); (people.get(x) ?? people.set(x, new Set()).get(x)!).add(who); });
    perNote.push(hs.size); linesPer.push(lines.length);
    bulletsPer.push(lines.filter((l) => /^-\s/.test(l)).length);
    plainLen.push(lines.join("\n").replace(/[\u0001\u0002]/g, "").length);
  }
  const MIN = 5;
  const template = [...freq.entries()].filter(([k, c]) => c >= MIN && (people.get(k)?.size ?? 0) >= MIN).sort((a, b) => b[1] - a[1])
    .map(([label, c]) => ({ label, in_notes: c, share_pct: Math.round((c / Math.max(devyce.length, 1)) * 1000) / 10 }));
  const stats = (xs: number[]) => xs.length ? { min: Math.min(...xs), median: median(xs), max: Math.max(...xs) } : null;
  return {
    status: res.status, sampled_calls: rows.length, notes: notes.length, devyce_notes: devyce.length,
    template_headings: template,
    rare_heading_labels_hidden: [...freq.keys()].filter((k) => (freq.get(k) ?? 0) < MIN || (people.get(k)?.size ?? 0) < MIN).length,
    headings_per_note: stats(perNote), lines_per_note: stats(linesPer), bullets_per_note: stats(bulletsPer),
    plain_text_length: stats(plainLen),
    note: "Heading labels appearing in 5+ notes about 5+ different people only (template structure). No call content returned.",
  };
}
