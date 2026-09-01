-- 0054_watchdog_realert_and_digest.sql
-- The watchdog told us, once, and then went quiet for eleven days.
--
-- On 21/08/2026 09:25 UTC check_sync_health() correctly fired three criticals — calls, candidates
-- and jobs — about 33 minutes after the incremental sync started throwing. It was right and it was
-- fast. It then never mentioned them again, because it only alerts on the TRANSITION into
-- critical. Over the same eleven days `deals` flapped critical->recovered 41 times (it was only
-- being driven by sporadic webhooks, a symptom of the same bug), so the three real alerts were
-- buried under 82 notifications about a non-problem.
--
-- Two changes, both aimed at the same failure mode: silence must never be indistinguishable from
-- health.
--
--   1. Re-alert while an entity STAYS critical, on a 6-hour backoff. A stall that is missed in the
--      first hour now nags until someone deals with it, without becoming per-5-minute spam.
--   2. sync_health_digest(): one message a day that ALWAYS posts, healthy or not. If the digest
--      stops arriving, the watchdog itself is dead — which is the one failure the watchdog could
--      never previously report.

create or replace function public.check_sync_health()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  h jsonb;
  e jsonb;
  prev text;
  prev_at timestamptz;
  webhook text;
  fired int := 0;
  -- Long enough not to spam a channel, short enough that a stall cannot quietly last a working day.
  repeat_after constant interval := interval '6 hours';
begin
  h := public.sync_health();
  select value into webhook from app_settings where key = 'alert_webhook_url';

  for e in select * from jsonb_array_elements(h->'entities') loop
    select status, created_at into prev, prev_at from sync_alerts
      where entity = e->>'entity' order by created_at desc limit 1;
    prev := coalesce(prev, 'recovered');   -- unseen entity == healthy baseline

    -- transition INTO critical -> alert
    if (e->>'status') = 'critical' and prev <> 'critical' then
      insert into sync_alerts(entity, status, reason, detail)
        values (e->>'entity', 'critical', e->>'reason', e);
      fired := fired + 1;
      if webhook is not null and length(webhook) > 0 then
        perform net.http_post(
          url := webhook,
          headers := '{"Content-Type":"application/json"}'::jsonb,
          body := jsonb_build_object('text',
            '🔴 Octagon sync ALERT — '||(e->>'entity')||': '||(e->>'reason')));
      end if;

    -- STILL critical -> re-alert on a backoff. This is the case that was missing.
    elsif (e->>'status') = 'critical' and prev = 'critical'
          and prev_at is not null and prev_at < now() - repeat_after then
      insert into sync_alerts(entity, status, reason, detail)
        values (e->>'entity', 'critical', e->>'reason', e);
      fired := fired + 1;
      if webhook is not null and length(webhook) > 0 then
        perform net.http_post(
          url := webhook,
          headers := '{"Content-Type":"application/json"}'::jsonb,
          body := jsonb_build_object('text',
            '🔴 Octagon sync STILL DOWN — '||(e->>'entity')||': '||(e->>'reason')));
      end if;

    -- transition OUT of critical -> recovery note
    elsif (e->>'status') <> 'critical' and prev = 'critical' then
      insert into sync_alerts(entity, status, reason, detail)
        values (e->>'entity', 'recovered', e->>'reason', e);
      fired := fired + 1;
      if webhook is not null and length(webhook) > 0 then
        perform net.http_post(
          url := webhook,
          headers := '{"Content-Type":"application/json"}'::jsonb,
          body := jsonb_build_object('text',
            '🟢 Octagon sync recovered — '||(e->>'entity')));
      end if;
    end if;
  end loop;

  return jsonb_build_object('overall', h->'overall', 'transitions', fired);
end;
$function$;

-- Daily heartbeat. Deliberately posts even when everything is fine: a silent channel should mean
-- "the digest is broken", not "probably healthy". That ambiguity is what cost us eleven days.
create or replace function public.sync_health_digest()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  h jsonb;
  overall text;
  webhook text;
  bad text;
begin
  h := public.sync_health();
  overall := h->>'overall';
  select value into webhook from app_settings where key = 'alert_webhook_url';

  select string_agg('• '||(x->>'entity')||' — '||(x->>'reason'), chr(10) order by x->>'entity')
    into bad
    from jsonb_array_elements(h->'entities') x
   where x->>'status' <> 'ok';

  if webhook is not null and length(webhook) > 0 then
    perform net.http_post(
      url := webhook,
      headers := '{"Content-Type":"application/json"}'::jsonb,
      body := jsonb_build_object('text',
        case when bad is null
          then '🟢 Octagon sync daily check — all entities healthy.'
          else '🟠 Octagon sync daily check — overall '||overall||':'||chr(10)||bad
        end));
  end if;

  return jsonb_build_object('overall', overall, 'unhealthy', coalesce(bad, ''));
end;
$function$;

revoke all on function public.check_sync_health() from public, anon, authenticated;
revoke all on function public.sync_health_digest() from public, anon, authenticated;
grant execute on function public.check_sync_health() to service_role;
grant execute on function public.sync_health_digest() to service_role;

-- 07:30 UTC — lands before the working day rather than during it.
do $do$
begin
  if exists (select 1 from cron.job where jobname = 'sync-health-digest') then
    perform cron.unschedule('sync-health-digest');
  end if;
  perform cron.schedule('sync-health-digest', '30 7 * * *', $job$select public.sync_health_digest();$job$);
end
$do$;
