// dashboard-data - RETIRED 03/11/2026. It returned firm Won revenue, the funnel, the deal pipeline
// and every consultant's figures to anyone with the URL, with no auth, from a public repo. Nothing
// live still called it: slack-command already reads dashboard_json() itself with the service key,
// and the session-start hook no longer falls back to it. Kept deployed as a stub that returns 410
// Gone and no data, so anything still pointing here fails loudly instead of silently.
Deno.serve(() => new Response(JSON.stringify({ error: "gone", message: "This endpoint has been retired. Use the Octagon connector." }),
  { status: 410, headers: { "Content-Type": "application/json", "Cache-Control": "no-store" } }));
