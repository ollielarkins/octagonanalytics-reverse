// recruitcrm-probe — TEMPORARY, read-only shape probe.
//
// Purpose: verify the RecruitCRM token works and discover the REAL payload
// shapes (the brief's open question) WITHOUT exposing candidate PII and without
// anyone pasting the token around. It reads the token from the environment
// secret RECRUITCRM_API_TOKEN, calls a few list endpoints with a tiny page,
// and returns ONLY the field names + value *types* of the first record — never
// the values themselves. Delete this function once the shapes are captured.

const BASE = "https://api.recruitcrm.io/v1";
// placements: probing whether the API exposes them at all — the placements table is empty, so
// fee-per-placement reporting is impossible until we know if this endpoint exists.
const ENDPOINTS = ["placements", "placement", "jobs"];

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

Deno.serve(async () => {
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
      };
    } catch (e) {
      report[ep] = { error: String(e) };
    }
  }

  return Response.json({ probed_at: "on-demand", base: BASE, endpoints: report });
});
