-- 0078_cron_manifest_watchdog.sql
-- The sync had not run since 10/09 because the cron entries were GONE, and nothing noticed. The
-- watchdog that would have noticed was itself one of the deleted jobs. Restoring them on 15/09 then
-- reproduced the same class of failure one level down: backfill-candidates-pass came back without its
-- partner backfill-candidates-drain, so the candidates pass could never complete - and health still
-- only said "stale", because staleness cannot distinguish a job that failed from a job that does not
-- exist.
--
-- sync_health watches whether feeds RAN. This watches whether the jobs that run them EXIST, are
-- active, and are on the cadence they were declared at. Schedule drift is treated as critical on
-- purpose: backfill-candidates-pass survived the outage at 0012's '0 2 * * *' instead of 0063's
-- '*/30 * * * *', which is a silently degraded job, not a healthy one.

create table if not exists public.cron_manifest (
  jobname  text primary key,
  schedule text not null,
  note     text,
  required boolean not null default true
);
alter table public.cron_manifest enable row level security;
revoke all on table public.cron_manifest from public, anon, authenticated;

insert into public.cron_manifest (jobname, schedule, note) values
  ('recruitcrm-incremental-sync',      '*/15 * * * *',      'live adds/edits for all entities (0005)'),
  ('history-recent',                   '* * * * *',         'candidate stage events - the funnel feed (0060)'),
  ('notes-recent',                     '*/15 * * * *',      'newest note pages, health-clocked'),
  ('backfill-candidates-pass',         '*/30 * * * *',      'STARTS a candidates deletion pass (0063)'),
  ('backfill-candidates-drain',        '*/3 * * * *',       'CONTINUES the pass to completion (0062) - useless without the pass, and the pass never finishes without it'),
  ('recruitcrm-reconcile-clients',     '5 * * * *',         'client deletion detection (0063)'),
  ('recruitcrm-reconcile-jobs',        '12 * * * *',        'job deletion detection (0063)'),
  ('recruitcrm-reconcile-deals',       '18 * * * *',        'deal deletion detection (0063)'),
  ('recruitcrm-reconcile-consultants', '0 3 * * *',         'consultant deletion detection (0007)'),
  ('offlimit-refresh',                 '25 3 * * *',        'do-not-approach flags'),
  ('sync-health-watchdog',             '*/5 * * * *',       'per-feed staleness alerting (0015)'),
  ('cron-manifest-watchdog',           '*/10 * * * *',      'this check - alerts if a scheduled job disappears'),
  ('sync-health-digest',               '30 7 * * *',        'daily sync summary to Slack'),
  ('digest-slack-morning',             '30 6,7 * * 1-5',    'morning brief'),
  ('digest-slack-evening',             '30 16,17 * * 1-5',  'day end'),
  ('digest-slack-weekly',              '0 7,8 * * 1',       'weekly'),
  ('purge-cron-history',               '15 3 * * *',        'trim cron.job_run_details'),
  ('purge-webhook-events',             '45 3 * * *',        'trim webhook_events')
on conflict (jobname) do update set schedule = excluded.schedule, note = excluded.note;

create or replace function public.check_cron_manifest()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  webhook text;
  e record;
  prev text;
  prev_at timestamptz;
  fired int := 0;
  problems int := 0;
  extra text;
  repeat_after constant interval := interval '6 hours';
begin
  select value into webhook from app_settings where key = 'alert_webhook_url';

  for e in
    select m.jobname,
           case when j.jobname is null then 'critical'
                when not j.active    then 'critical'
                when j.schedule is distinct from m.schedule then 'critical'
                else 'ok' end as st,
           case when j.jobname is null then 'MISSING from cron.job'
                when not j.active    then 'disabled'
                when j.schedule is distinct from m.schedule
                     then format('schedule drift: expected %s, found %s', m.schedule, j.schedule)
                else 'ok' end as rs
      from cron_manifest m
      left join cron.job j on j.jobname = m.jobname
     where m.required
     order by m.jobname
  loop
    if e.st = 'critical' then problems := problems + 1; end if;

    select status, created_at into prev, prev_at from sync_alerts
      where entity = 'cron:'||e.jobname order by created_at desc limit 1;
    prev := coalesce(prev, 'recovered');

    if e.st = 'critical' and prev <> 'critical' then
      insert into sync_alerts(entity, status, reason, detail)
        values ('cron:'||e.jobname, 'critical', e.rs, jsonb_build_object('jobname', e.jobname, 'reason', e.rs));
      fired := fired + 1;
      if webhook is not null and length(webhook) > 0 then
        perform net.http_post(url := webhook,
          headers := '{"Content-Type":"application/json"}'::jsonb,
          body := jsonb_build_object('text', '🔴 Octagon CRON ALERT — '||e.jobname||': '||e.rs));
      end if;

    elsif e.st = 'critical' and prev = 'critical'
          and prev_at is not null and prev_at < now() - repeat_after then
      insert into sync_alerts(entity, status, reason, detail)
        values ('cron:'||e.jobname, 'critical', e.rs, jsonb_build_object('jobname', e.jobname, 'reason', e.rs));
      fired := fired + 1;
      if webhook is not null and length(webhook) > 0 then
        perform net.http_post(url := webhook,
          headers := '{"Content-Type":"application/json"}'::jsonb,
          body := jsonb_build_object('text', '🔴 Octagon CRON STILL MISSING — '||e.jobname||': '||e.rs));
      end if;

    elsif e.st = 'ok' and prev = 'critical' then
      insert into sync_alerts(entity, status, reason, detail)
        values ('cron:'||e.jobname, 'recovered', e.rs, jsonb_build_object('jobname', e.jobname));
      fired := fired + 1;
      if webhook is not null and length(webhook) > 0 then
        perform net.http_post(url := webhook,
          headers := '{"Content-Type":"application/json"}'::jsonb,
          body := jsonb_build_object('text', '🟢 Octagon cron restored — '||e.jobname));
      end if;
    end if;
  end loop;

  -- Jobs present but not declared. Reported, never alerted: an ad-hoc job is somebody working, not a
  -- fault. It belongs in the manifest once it is meant to be permanent.
  select string_agg(j.jobname, ', ' order by j.jobname) into extra
    from cron.job j left join cron_manifest m on m.jobname = j.jobname
   where m.jobname is null;

  return jsonb_build_object(
    'expected', (select count(*) from cron_manifest where required),
    'problems', problems,
    'transitions', fired,
    'undeclared', coalesce(extra, ''));
end $fn$;

revoke all on function public.check_cron_manifest() from public, anon, authenticated;
grant execute on function public.check_cron_manifest() to service_role;

do $do$
begin
  if exists (select 1 from cron.job where jobname = 'cron-manifest-watchdog') then
    perform cron.unschedule('cron-manifest-watchdog');
  end if;
  perform cron.schedule('cron-manifest-watchdog', '*/10 * * * *', $job$select public.check_cron_manifest();$job$);
end
$do$;
