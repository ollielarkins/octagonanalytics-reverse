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
    };
  } catch (e) { return { error: String(e) }; }
}

Deno.serve(async (req) => {
  {
    const probeUrl = new URL(req.url);
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
