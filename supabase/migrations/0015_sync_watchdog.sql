-- 0015_sync_watchdog.sql
-- Sync-failure monitoring & alerting (M7 hardening).
--
-- The platform's whole value is "trusted, live numbers". The dangerous failure
-- mode is a SILENT sync stall: the dashboard keeps showing the last-good figures
-- and looks live when it's actually stale. This migration closes that gap.
--
--   sync_health()        classifies each tracked sync into ok / warn / critical
--   dashboard_json()      now embeds health, so stale data can never *look* fresh
--   check_sync_health()   watchdog: logs state transitions + optional webhook alert
--   pg_cron every 5 min   runs the watchdog
--
-- Category-aware thresholds (this is the crux):
--   * live entities (candidates/clients/consultants/jobs) run every 2 min via the
--     incremental cron -> warn at 10 min stale, critical at 30 min or on an error status.
--   * reconcile:* run nightly -> warn at 26h, critical at 50h.
--   * 'history' is a ONE-OFF manual backfill (already complete). It is deliberately
--     NOT tracked here, or it would false-alarm forever.

-- ---------------------------------------------------------------------------
-- 1. Health classifier
-- ---------------------------------------------------------------------------
create or replace function public.sync_health()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
  with cfg(entity, category, warn_min, crit_min) as (
    values
      ('candidates','live',10,30),
      ('clients','live',10,30),
      ('consultants','live',10,30),
      ('jobs','live',10,30),
      ('reconcile:clients','reconcile',1560,3000),  -- 26h warn / 50h critical
      ('reconcile:jobs','reconcile',1560,3000)
  ),
  good(status) as (values ('ok'),('caught_up'),('complete'),('resume_next_page')),
  ev as (
    select c.entity, c.category, c.warn_min, c.crit_min,
           s.last_run_at, s.last_status,
           round(extract(epoch from (now()-s.last_run_at))/60)::int as mins
    from cfg c left join sync_state s on s.entity = c.entity
  ),
  cls as (
    select entity, category, last_run_at, last_status, mins,
      case
        when last_run_at is null then 'critical'
        when category='live' and last_status is not null
             and last_status not in (select status from good) then 'critical'
        when mins >= crit_min then 'critical'
        when mins >= warn_min then 'warn'
        else 'ok'
      end as status,
      case
        when last_run_at is null then 'no sync run on record'
        when category='live' and last_status is not null
             and last_status not in (select status from good) then 'error status: '||last_status
        when mins >= crit_min then 'stale: '||mins||' min since last run'
        when mins >= warn_min then 'slowing: '||mins||' min since last run'
        else 'fresh'
      end as reason
    from ev
  )
  select jsonb_build_object(
    'generated_at', now(),
    'overall', (select case
                  when bool_or(status='critical') then 'critical'
                  when bool_or(status='warn') then 'warn'
                  else 'ok' end from cls),
    'entities', (select jsonb_agg(jsonb_build_object(
        'entity', entity, 'category', category, 'last_run_at', last_run_at,
        'minutes_stale', mins, 'last_status', last_status,
        'status', status, 'reason', reason)
        order by (status='critical') desc, (status='warn') desc, entity) from cls)
  );
$function$;

revoke all on function public.sync_health() from public, anon;
grant execute on function public.sync_health() to service_role, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Config + alert-log tables
-- ---------------------------------------------------------------------------
-- Optional alert webhook (Slack/Discord/generic). Held in a locked table because
-- a webhook URL is itself a secret. Only service_role (RLS bypass) can read it.
create table if not exists public.app_settings (
  key        text primary key,
  value      text,
  updated_at timestamptz not null default now()
);
alter table public.app_settings enable row level security;  -- no policies => service_role only
insert into public.app_settings(key, value)
  values ('alert_webhook_url', null)
  on conflict (key) do nothing;

-- Append-only alert log. Operational metadata (no PII) — readable by authenticated
-- so a future ops view / the dashboard can show recent alerts.
create table if not exists public.sync_alerts (
  id         uuid primary key default gen_random_uuid(),
  entity     text not null,
  status     text not null,           -- 'critical' | 'recovered'
  reason     text,
  detail     jsonb,
  created_at timestamptz not null default now()
);
alter table public.sync_alerts enable row level security;
drop policy if exists sync_alerts_read_auth on public.sync_alerts;
create policy sync_alerts_read_auth on public.sync_alerts for select to authenticated using (true);

-- ---------------------------------------------------------------------------
-- 3. Watchdog: log transitions, fire webhook on critical / recovery
-- ---------------------------------------------------------------------------
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
  webhook text;
  fired int := 0;
begin
  h := public.sync_health();
  select value into webhook from app_settings where key = 'alert_webhook_url';

  for e in select * from jsonb_array_elements(h->'entities') loop
    select status into prev from sync_alerts
      where entity = e->>'entity' order by created_at desc limit 1;
    prev := coalesce(prev, 'recovered');   -- unseen entity == healthy baseline

    -- transition INTO critical -> alert (dedup: only on state change)
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

revoke all on function public.check_sync_health() from public, anon, authenticated;
grant execute on function public.check_sync_health() to service_role;

-- ---------------------------------------------------------------------------
-- 4. Embed health in the dashboard payload (so stale data never LOOKS fresh)
-- ---------------------------------------------------------------------------
create or replace function public.dashboard_json()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
  select jsonb_build_object(
    'generated_at', now(),
    'health', (select public.sync_health()),
    'kpis', jsonb_build_object(
      'cv_2026',      (select count(*) from candidate_stage_events where stage_metric='cv_sent' and event_date >= '2026-01-01'),
      'placed_2026',  (select count(*) from candidate_stage_events where stage_metric='placed'  and event_date >= '2026-01-01'),
      'candidates',   (select count(distinct candidate_id) from candidate_stage_events),
      'jobs',         (select count(*) from jobs where deleted_at is null),
      'open_jobs',    (select count(*) from jobs where deleted_at is null and status ilike '%open%'),
      'clients',      (select count(*) from clients where deleted_at is null),
      'consultants',  (select count(*) from consultants where deleted_at is null),
      'open_pipeline',(select coalesce(sum(deal_value),0) from deals where deal_stage not in ('Won','Lost')),
      'won',          (select coalesce(sum(deal_value),0) from deals where deal_stage='Won'),
      'cv_all',       (select count(*) from candidate_stage_events where stage_metric='cv_sent'),
      'placed_all',   (select count(*) from candidate_stage_events where stage_metric='placed')
    ),
    'funnel', (select jsonb_object_agg(stage_metric, n) from (
        select stage_metric, count(*) n from candidate_stage_events
        where event_date >= '2026-01-01'
          and stage_metric in ('cv_sent','interview_request','first_interview','second_interview','offered','placed')
        group by stage_metric) f),
    'monthly', (select jsonb_agg(jsonb_build_object(
          'month', to_char(ms,'YYYY-MM'),'cv_sent',cv,'interview_request',ir,'first_interview',fi,
          'second_interview',si,'offered',off,'placed',pl) order by ms) from (
        select date_trunc('month',event_date) ms,
          count(*) filter (where stage_metric='cv_sent') cv,
          count(*) filter (where stage_metric='interview_request') ir,
          count(*) filter (where stage_metric='first_interview') fi,
          count(*) filter (where stage_metric='second_interview') si,
          count(*) filter (where stage_metric='offered') off,
          count(*) filter (where stage_metric='placed') pl
        from candidate_stage_events where event_date >= (current_date - interval '18 months')
        group by 1) m),
    'consultants', (select jsonb_agg(jsonb_build_object(
          'name',name,'cv_sent',cv,'interview_request',ir,'first_interview',fi,'offered',off,'placed',pl)
          order by cv desc) from (
        select co.name,
          count(*) filter (where e.stage_metric='cv_sent') cv,
          count(*) filter (where e.stage_metric='interview_request') ir,
          count(*) filter (where e.stage_metric='first_interview') fi,
          count(*) filter (where e.stage_metric='offered') off,
          count(*) filter (where e.stage_metric='placed') pl
        from candidate_stage_events e
        join jobs j on e.job_slug=j.slug
        join consultants co on j.consultant_id=co.id
        where e.event_date >= '2026-01-01'
        group by co.name
        having count(*) filter (where e.stage_metric='cv_sent') > 0) c),
    'pipeline', (select jsonb_agg(jsonb_build_object('stage',coalesce(deal_stage,'(none)'),'deals',d,'value',v)
          order by v desc) from (
        select deal_stage, count(*) d, coalesce(sum(deal_value),0) v from deals group by deal_stage) p)
  );
$function$;

-- ---------------------------------------------------------------------------
-- 5. Schedule the watchdog every 5 minutes
-- ---------------------------------------------------------------------------
select cron.unschedule('sync-health-watchdog')
  where exists (select 1 from cron.job where jobname = 'sync-health-watchdog');
select cron.schedule('sync-health-watchdog', '*/5 * * * *', $$select public.check_sync_health();$$);
