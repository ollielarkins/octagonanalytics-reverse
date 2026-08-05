-- 0024_attention_alerts.sql
-- Proactive "what needs attention" layer — turns the platform from pull-only into push.
--   stalled_report()  firm-wide: aging offers + stalled candidates, owner-attributed
--   my_day()          one consultant's attention list (scoped to whoever asks)
--   post_standup()    weekday Slack standup from stalled_report() -> standup_webhook_url
--   pg_cron Mon–Fri 08:00 runs it
--
-- "Active" = current stage is still in play (CV Sent..Offered) on a non-deleted job.
-- "Current stage" = the latest event per (candidate, job). Owner = the job's consultant (D9).

-- active-stage set, reused below
-- (cv_sent, interview_request, first_interview, second_interview, third_interview, offered)

create or replace function public.stalled_report(p_stall_days int default 10, p_offer_days int default 5)
returns jsonb language sql stable security definer set search_path to 'public' as $function$
  with latest as (
    select distinct on (e.candidate_slug, e.job_slug)
      e.candidate_slug, coalesce(e.candidate_name, e.candidate_slug) candidate, e.job_slug, e.job_title,
      e.stage_metric, e.stage_name, e.event_date, co.name consultant, j.status job_status
    from candidate_stage_events e
    join jobs j on j.slug = e.job_slug and j.deleted_at is null
    join consultants co on j.consultant_id = co.id and co.deleted_at is null
    order by e.candidate_slug, e.job_slug, e.event_timestamp desc
  ),
  active as (
    select *, (current_date - event_date) days from latest
    where stage_metric in ('cv_sent','interview_request','first_interview','second_interview','third_interview','offered')
  )
  select jsonb_build_object(
    'generated_at', now(),
    'thresholds', jsonb_build_object('stall_days', p_stall_days, 'offer_days', p_offer_days),
    'definition', 'Candidates whose current stage is still active (CV Sent..Offered) on a non-deleted job, with no movement beyond the threshold. Aging offers use the shorter offer threshold. Owner-attributed.',
    'aging_offers', (select coalesce(jsonb_agg(jsonb_build_object(
        'consultant',consultant,'candidate',candidate,'job_title',job_title,'job_slug',job_slug,
        'candidate_slug',candidate_slug,'days_since_offer',days,'job_status',job_status) order by days desc), '[]'::jsonb)
      from active where stage_metric='offered' and days >= p_offer_days),
    'stalled', (select coalesce(jsonb_agg(jsonb_build_object(
        'consultant',consultant,'candidate',candidate,'job_title',job_title,'job_slug',job_slug,
        'candidate_slug',candidate_slug,'stage',stage_name,'days_stalled',days,'job_status',job_status) order by days desc), '[]'::jsonb)
      from active where stage_metric <> 'offered' and days >= p_stall_days)
  );
$function$;

create or replace function public.my_day(p_consultant_id bigint default null, p_consultant text default null)
returns jsonb language sql stable security definer set search_path to 'public' as $function$
  with me as (
    select id, recruitcrm_id, name from consultants
    where deleted_at is null and (
      (p_consultant_id is not null and recruitcrm_id = p_consultant_id)
      or (p_consultant is not null and name ilike '%'||p_consultant||'%'))
    order by (p_consultant_id is not null) desc limit 1
  ),
  latest as (
    select distinct on (e.candidate_slug, e.job_slug)
      coalesce(e.candidate_name, e.candidate_slug) candidate, e.job_title, e.stage_metric, e.stage_name, e.event_date
    from candidate_stage_events e
    join jobs j on j.slug = e.job_slug and j.deleted_at is null and j.consultant_id = (select id from me)
    order by e.candidate_slug, e.job_slug, e.event_timestamp desc
  ),
  active as (select *, (current_date - event_date) days from latest
    where stage_metric in ('cv_sent','interview_request','first_interview','second_interview','third_interview','offered'))
  select case when (select id from me) is null then jsonb_build_object('error','consultant not found')
  else jsonb_build_object(
    'consultant', (select name from me),
    'generated_at', now(),
    'aging_offers', (select coalesce(jsonb_agg(jsonb_build_object('candidate',candidate,'job_title',job_title,'days',days) order by days desc),'[]'::jsonb)
       from active where stage_metric='offered' and days >= 5),
    'stalled', (select coalesce(jsonb_agg(jsonb_build_object('candidate',candidate,'job_title',job_title,'stage',stage_name,'days',days) order by days desc),'[]'::jsonb)
       from active where stage_metric <> 'offered' and days >= 10),
    'active_in_play', (select count(*) from active),
    'cold_open_roles', (select count(*) from jobs j where j.deleted_at is null and j.status='Open' and j.consultant_id = (select id from me)
        and not exists (select 1 from candidate_stage_events e where e.job_slug = j.slug and e.event_date > current_date - 14)),
    'placed_last_7d', (select count(*) from candidate_stage_events e join jobs j on j.slug = e.job_slug
        where j.consultant_id = (select id from me) and e.stage_metric='placed' and e.event_date > current_date - 7)
  ) end;
$function$;

create or replace function public.post_standup()
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare r jsonb; hook text; msg text; offers text; stalls text;
begin
  r := public.stalled_report(10, 5);
  select value into hook from app_settings where key = 'standup_webhook_url';
  select string_agg('• '||(x->>'consultant')||': '||(x->>'candidate')||' — offer out '||(x->>'days_since_offer')||'d ('||(x->>'job_title')||')', E'\n')
    into offers from jsonb_array_elements(r->'aging_offers') x;
  select string_agg('• '||(x->>'consultant')||': '||(x->>'candidate')||' — '||(x->>'stage')||' '||(x->>'days_stalled')||'d ('||(x->>'job_title')||')', E'\n')
    into stalls from (select x from jsonb_array_elements(r->'stalled') x limit 15) s;
  msg := '*Octagon daily standup* ('||to_char(now(),'Dy DD Mon')||')'||E'\n'
      ||':hourglass: *Aging offers* (>5d)'||E'\n'||coalesce(offers,'_none_')||E'\n\n'
      ||':warning: *Stalled candidates* (>10d, top 15)'||E'\n'||coalesce(stalls,'_none_');
  if hook is not null and length(hook) > 0 then
    perform net.http_post(url := hook, headers := '{"Content-Type":"application/json"}'::jsonb, body := jsonb_build_object('text', msg));
  end if;
  return jsonb_build_object('posted', hook is not null and length(hook) > 0,
    'aging_offers', jsonb_array_length(r->'aging_offers'), 'stalled', jsonb_array_length(r->'stalled'));
end $function$;

insert into public.app_settings(key, value) values ('standup_webhook_url', null) on conflict (key) do nothing;

revoke all on function public.stalled_report(int,int)      from public, anon, authenticated;
revoke all on function public.my_day(bigint,text)          from public, anon, authenticated;
revoke all on function public.post_standup()               from public, anon, authenticated;
grant execute on function public.stalled_report(int,int)   to service_role;
grant execute on function public.my_day(bigint,text)       to service_role;
grant execute on function public.post_standup()            to service_role;

select cron.unschedule('daily-standup') where exists (select 1 from cron.job where jobname = 'daily-standup');
select cron.schedule('daily-standup', '0 8 * * 1-5', $$select public.post_standup();$$);
