-- 0071_email_digests.sql
-- Data behind the three scheduled email digests for Ollie.
--
-- Cadence was chosen from measured behaviour, not preference. Over 20 working days
-- (10/08-05/09/2026): 43.5% of all stage activity happens before 10:00, 68.2% by 13:00, 96.3% by
-- 16:00 and 99.6% by 17:00. So a midday email captures an incomplete day, arrives too late to
-- change the morning that already happened, and repeats itself at day end - it was dropped.
--
--   morning  07:30 Mon-Fri  forward-looking: what needs a decision today, before the 43.5% burst
--   evening  17:30 Mon-Fri  backward-looking: a complete day, since activity is 99.6% done by 17:00
--   weekly   08:00 Mon      the slow movers: cold roles and job order forms, which barely change daily
--
-- Placements are deliberately NOT on a daily schedule: only 3 of those 20 working days had one, so
-- a daily placements email would be empty 85% of the time, which trains the reader to ignore it
-- before the day it matters. They appear inside the evening digest when they occur and are silent
-- otherwise.

-- Morning: what needs a decision today.
create or replace function public.digest_morning()
returns jsonb language sql stable security definer set search_path to 'public'
as $function$
  with wk as (select date_trunc('week', current_date)::date d),
  yest as (
    select case when extract(dow from current_date) = 1
           then current_date - 3 else current_date - 1 end as d
  ),
  y as (
    select
      count(distinct e.candidate_slug||'|'||e.job_slug) filter (where e.stage_metric='cv_sent') cv,
      count(distinct e.candidate_slug||'|'||e.job_slug) filter (where e.stage_metric='interview_request') ir,
      count(distinct e.candidate_slug||'|'||e.job_slug) filter (where e.stage_metric='first_interview') fi,
      count(distinct e.candidate_slug||'|'||e.job_slug) filter (where e.stage_metric='placed') pl
    from candidate_stage_events e
    join jobs j on j.slug=e.job_slug and j.deleted_at is null
    where e.event_date = (select d from yest)
  ),
  ycalls as (
    select count(*) total,
           count(*) filter (where custom_call_type='Contact - Prospect (BD)') bd,
           count(*) filter (where custom_call_type in ('Contact - Client','Contact - Client Info')) cc
    from call_activity where call_date = (select d from yest)
  ),
  week as (
    select
      count(distinct e.candidate_slug||'|'||e.job_slug) filter (where e.stage_metric='cv_sent') cv,
      count(distinct e.candidate_slug||'|'||e.job_slug) filter (where e.stage_metric='interview_request') ir,
      count(distinct e.candidate_slug||'|'||e.job_slug) filter (where e.stage_metric='first_interview') fi
    from candidate_stage_events e
    join jobs j on j.slug=e.job_slug and j.deleted_at is null
    where e.event_date >= (select d from wk)
  )
  select jsonb_build_object(
    'kind', 'morning',
    'generated_at', now(),
    'for_date', current_date,
    'previous_working_day', (select d from yest),
    'yesterday', (select jsonb_build_object(
        'cv_sent', cv, 'interview_request', ir, 'first_interview', fi, 'placed', pl,
        'calls', (select total from ycalls),
        'bd_calls', (select bd from ycalls),
        'client_calls', (select cc from ycalls)) from y),
    'week_to_date', (select jsonb_build_object('cv_sent', cv, 'interview_request', ir, 'first_interview', fi) from week),
    'chase', jsonb_build_object(
      'aging_offers',      (select coalesce((public.stalled_report(10,5,60)->'aging_offers'), '[]'::jsonb)),
      'unbooked_requests', (select coalesce((public.interview_requests_unbooked(30)->'requests'), '[]'::jsonb)),
      'awaiting_feedback', (select coalesce((public.awaiting_feedback_report(2,30)->'candidates'), '[]'::jsonb))),
    'cold_roles', (select coalesce((public.cold_jobs(7, null, 100)->'jobs'), '[]'::jsonb)),
    'health', (select public.sync_health())
  );
$function$;

-- Evening: a complete day, sent after activity has stopped.
create or replace function public.digest_evening()
returns jsonb language sql stable security definer set search_path to 'public'
as $function$
  with t as (
    select coalesce(co.name, e.consultant) consultant, e.stage_metric,
           e.candidate_slug||'|'||e.job_slug pair
    from candidate_stage_events e
    join jobs j on j.slug=e.job_slug and j.deleted_at is null
    left join consultants co on co.recruitcrm_id = e.consultant_id
    where e.event_date = current_date
  ),
  per as (
    select consultant,
      count(distinct pair) filter (where stage_metric='cv_sent') cv,
      count(distinct pair) filter (where stage_metric='interview_request') ir,
      count(distinct pair) filter (where stage_metric='first_interview') fi,
      count(distinct pair) filter (where stage_metric='placed') pl
    from t where consultant is not null group by consultant
  ),
  c as (
    select count(*) total, count(*) filter (where connected) conn,
           count(*) filter (where custom_call_type='Contact - Prospect (BD)') bd,
           count(*) filter (where custom_call_type in ('Contact - Client','Contact - Client Info')) cc,
           count(*) filter (where custom_call_type is not null) tagged
    from call_activity where call_date = current_date
  )
  select jsonb_build_object(
    'kind', 'evening',
    'generated_at', now(),
    'for_date', current_date,
    'totals', (select jsonb_build_object(
        'cv_sent', coalesce(sum(cv),0), 'interview_request', coalesce(sum(ir),0),
        'first_interview', coalesce(sum(fi),0), 'placed', coalesce(sum(pl),0)) from per),
    'by_consultant', (select coalesce(jsonb_agg(jsonb_build_object(
        'name', consultant, 'cv_sent', cv, 'interview_request', ir,
        'first_interview', fi, 'placed', pl) order by cv desc, ir desc), '[]'::jsonb)
      from per where cv+ir+fi+pl > 0),
    'calls', (select jsonb_build_object(
        'total', total, 'connected', conn, 'tagged', tagged,
        'bd', bd, 'client', cc,
        'connect_rate', round(100.0*conn/nullif(total,0),1),
        'tagged_pct', round(100.0*tagged/nullif(total,0),1)) from c),
    'placements', (select coalesce((public.placements_with_fees(current_date, current_date+1)->'placements'), '[]'::jsonb)),
    'new_jobs', (select coalesce((public.new_jobs_report(current_date, current_date+1)->'jobs'), '[]'::jsonb)),
    'health', (select public.sync_health())
  );
$function$;

-- Weekly: the slow movers, plus last week closed out.
create or replace function public.digest_weekly()
returns jsonb language sql stable security definer set search_path to 'public'
as $function$
  with lw as (
    select (date_trunc('week', current_date) - interval '7 days')::date lo,
           date_trunc('week', current_date)::date hi
  )
  select jsonb_build_object(
    'kind', 'weekly',
    'generated_at', now(),
    'week_starting', date_trunc('week', current_date)::date,
    'last_week', jsonb_build_object(
      'from', (select lo from lw), 'to', (select hi from lw),
      'funnel', (select public.funnel_report((select lo from lw), (select hi from lw), null, null))),
    'cold_roles', (select coalesce((public.cold_jobs(7, null, 100)->'jobs'), '[]'::jsonb)),
    'new_jobs', (select public.new_jobs_report((select lo from lw), (select hi from lw), null)),
    'kpis', (select public.kpis_report()),
    'health', (select public.sync_health())
  );
$function$;

revoke all on function public.digest_morning() from public, anon, authenticated;
revoke all on function public.digest_evening() from public, anon, authenticated;
revoke all on function public.digest_weekly() from public, anon, authenticated;
grant execute on function public.digest_morning() to service_role;
grant execute on function public.digest_evening() to service_role;
grant execute on function public.digest_weekly() to service_role;

-- Recipient lives in app_settings (service_role only) rather than in the function body, so
-- changing who gets it is a SQL update and not a redeploy.
insert into public.app_settings (key, value)
values ('digest_to_email', 'olarkins@octagongroup.co.uk')
on conflict (key) do update set value = excluded.value;
