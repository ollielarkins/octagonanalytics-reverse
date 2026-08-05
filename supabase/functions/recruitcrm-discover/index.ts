// recruitcrm-discover — GUTTED + LOCKED after use (verify_jwt=true). Returns 410.
// All discovery findings are recorded in the migrations/README. Last round: call-logs.
//   Endpoint: GET /v1/call-logs (top-level, paginated, no total).
//   Fields: id, call_type (CALL_OUTGOING|CALL_INCOMING), custom_call_type {id,label}
//   (labels e.g. 'Contact - Prospect (BD)', 'Contact - Client', 'Interview Feedback'),
//   call_started_on (ISO), duration (int SECONDS; 0 = not connected), created_by (numeric
//   user id = the caller), related_to + related_to_type (candidate|contact|company),
//   contact_number + call_notes (PII — never synced).
Deno.serve(() => new Response(JSON.stringify({ gone: true }), { status: 410, headers: { "Content-Type": "application/json" } }));
