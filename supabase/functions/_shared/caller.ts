// Who may call a locked function (recruitcrm-sync, recruitcrm-probe, inbox-sync, daily-queue,
// digest-email, coach-dm).
//
// verify_jwt = true only proves the caller holds SOME project JWT, and the anon key is public: it
// is in the cron migrations of this public repo. Until 29/10/2026 anyone with it could render the
// morning digest (candidate names), re-send the queue and coach DMs, or restart the sync backfill.
// Now a caller must present either:
//   - the service-role key as its bearer: other functions calling in (octagon-mcp's write-through,
//     recruitcrm-webhook), which already send it; or
//   - x-octagon-cron equal to CRON_SECRET: pg_cron, through public.cron_headers() (migration 0132),
//     which reads the same value from Vault.
// Fails closed: with CRON_SECRET unset, only the service-role key gets in.

function same(a: string, b: string) {
  const x = new TextEncoder().encode(a), y = new TextEncoder().encode(b);
  let d = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) d |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return d === 0;
}

export function trustedCaller(req: Request): boolean {
  const secret = Deno.env.get("CRON_SECRET") ?? "";
  const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const bearer = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
  const cron = req.headers.get("x-octagon-cron") ?? "";
  return (secret.length >= 32 && same(cron, secret)) || (service.length > 0 && same(bearer, service));
}

export function forbidden() {
  return Response.json({ error: "forbidden" }, { status: 403 });
}
