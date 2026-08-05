// recruitcrm-discover — GUTTED + LOCKED after use (verify_jwt=true). Returns 410.
// Discovery findings across rounds (2026-08-04/05):
//   * 3 hiring pipelines: Master (0), Calnex (4309), Executive (3200). Full stage set
//     incl. 3rd Interview 394846 + Shortlist 511685. No "Internal Interview" stage.
//   * Client/BD funnel lives in the company "Company Status" custom field (3072/4584).
//   * Notes: top-level /v1/notes resource (GET /v1/notes?related_to={slug}). A note has
//     note_type, description (text), related_to, related_to_type, created_by, updated_by,
//     associated_candidates[]/_jobs[]/_companies[]/_contacts[]/_deals[], collaborator_*[].
//     add_note create contract (POST /v1/notes) still to confirm before building.
Deno.serve(() => new Response(JSON.stringify({ gone: true, note: "discovery probe retired" }), { status: 410, headers: { "Content-Type": "application/json" } }));
