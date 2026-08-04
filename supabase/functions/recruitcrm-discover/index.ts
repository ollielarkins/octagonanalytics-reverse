// recruitcrm-discover — GUTTED + LOCKED after use (verify_jwt=true). Returns 410.
// Discovery complete (2026-08-04). Findings:
//   * 3 hiring pipelines: Master (0), Calnex (4309), Executive (3200).
//   * Full stage set (union): Assigned 1, Applied 10, Shortlist 511685, CV Sent 390955,
//     Interview Request 381800, 1st Interview 381799, 2nd Interview 381801,
//     3rd Interview 394846, Rejected-Client 381802, Rejected-Consultant 481042,
//     Offered 381805, Placed 8.  NO "Internal Interview" stage exists.
//   * Unmapped-but-real (were being dropped): 3rd Interview 394846, Shortlist 511685.
//   * Client/BD funnel lives in the company "Company Status" custom field
//     (3072/4584 classified: Prospect 2806, Client 170, Passive 60, Blocklisted 26,
//     Engaged 6, Do-not-contact 4). The contact pipeline holds only 15 records.
Deno.serve(() => new Response(JSON.stringify({ gone: true, note: "discovery probe retired" }), { status: 410, headers: { "Content-Type": "application/json" } }));
