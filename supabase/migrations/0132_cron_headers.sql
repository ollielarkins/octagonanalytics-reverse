-- 0132_cron_headers.sql
-- One place for the headers pg_cron sends to the locked edge functions, now carrying a real secret.
--
-- The locked functions (verify_jwt = true) were reached with the anon key, which is public: it is
-- hardcoded in twelve cron jobs and committed in this public repo. Anyone holding it could render
-- the morning digest (candidate names), re-send the queue and coach DMs, or restart the sync
-- backfill. Found in the platform audit, 29/10/2026. Each locked function now also requires x-octagon-cron = CRON_SECRET (or the service-role key, which
-- other functions use); see supabase/functions/_shared/caller.ts.
--
-- cron_headers() keeps the anon bearer (the gateway still checks a JWT) and adds x-octagon-cron
-- from Vault secret 'cron_secret'. The same value must be set as the CRON_SECRET function secret.
-- Order: create both secrets, apply this, then deploy the six functions. Applied before the
-- functions are deployed it changes nothing: the old functions ignore the extra header.

create or replace function public.cron_headers()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'Authorization', 'Bearer ' || s.value,
    'Content-Type', 'application/json',
    'x-octagon-cron', coalesce((select decrypted_secret from vault.decrypted_secrets where name = 'cron_secret' limit 1), ''))
  from public.app_settings s where s.key = 'cron_bearer';
$$;
-- Called only by pg_cron (as postgres) and the *_if_due functions below; it returns a secret.
revoke execute on function public.cron_headers() from public, anon, authenticated;

-- The four helpers that call locked functions build hdrs inline; point them at cron_headers().
-- Guarded per 0083: a definition that no longer matches raises instead of silently not changing.
do $$
declare
  fn text;
  def text;
  new_def text;
  pat constant text := 'select jsonb_build_object\(''Authorization'', ''Bearer '' \|\| value, ''Content-Type'', ''application/json''\)\s+into hdrs from app_settings where key = ''cron_bearer'';';
begin
  foreach fn in array array['action_queue_if_due', 'coach_if_due', 'meetings_quarter_refresh', 'send_digest_if_due'] loop
    select pg_get_functiondef(p.oid) into def
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = fn;
    if def is null then raise exception '0132: function % not found', fn; end if;
    new_def := regexp_replace(def, pat, 'hdrs := public.cron_headers();');
    if new_def = def then raise exception '0132: % no longer builds hdrs the expected way; not changed', fn; end if;
    execute new_def;
  end loop;
end $$;

-- The twelve jobs that call functions directly: eleven with the anon key hardcoded, plus
-- inbox-poll reading cron_bearer inline. Each must change, or the migration fails.
do $$
declare
  j record;
  cmd text;
  n int := 0;
begin
  for j in select jobid, jobname, command from cron.job where command ilike '%/functions/v1/%' loop
    cmd := regexp_replace(j.command,
      'headers\s*:=\s*jsonb_build_object\(''Authorization'',\s*''Bearer [A-Za-z0-9._-]+'',\s*''Content-Type'',\s*''application/json''\)',
      'headers:=public.cron_headers()');
    cmd := regexp_replace(cmd,
      'headers\s*:=\s*\(select jsonb_build_object\(''Authorization'', ''Bearer '' \|\| value, ''Content-Type'', ''application/json''\)\s+from public\.app_settings where key = ''cron_bearer''\)',
      'headers := public.cron_headers()');
    if cmd = j.command then raise exception '0132: cron job % calls a function but its headers did not match; not changed', j.jobname; end if;
    perform cron.alter_job(j.jobid, command := cmd);
    n := n + 1;
  end loop;
  if n <> 12 then raise exception '0132: expected 12 function-calling cron jobs, found %', n; end if;
end $$;
