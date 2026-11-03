// dashboard - RETIRED 03/11/2026. A public HTML page rendered from dashboard_json(): firm figures and
// every consultant by name to anyone with the URL, from a public repo. Retired alongside its JSON
// twin dashboard-data the same day. The live dashboard is the get_dashboard widget in the Octagon
// connector, behind each person's token. Kept deployed as a 410 stub with no data.
Deno.serve(() => new Response(
  "<!doctype html><meta charset=utf-8><title>Retired</title><p>This page has been retired. The Octagon dashboard is in Claude: ask for the dashboard.</p>",
  { status: 410, headers: { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" } }));
