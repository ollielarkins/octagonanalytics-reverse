-- 0135_daily_activity.sql
-- One day's CV sends and interview requests, by name: the lists Dale emails round each morning
-- (RecruitCRM report screenshots). Asked for 30/10/2026: his own attempt with Claude "was getting the
-- dates wrong and sending all CVs for random dates", because no tool listed a day's moves by name
-- and the model improvised from current-stage views.
--
-- Each row is a candidate-job pair moved to that stage on the day, credited to whoever moved it
-- (the funnel rule), with the pair's CURRENT stage and its date, as Dale's report shows it. Checked
-- against his 29/10/2026 emails: 8 CVs and 5 interview requests, same people, same current stages.
-- Default day is the previous working day in UK time (Friday when run on a Monday).

create or replace function public.daily_activity(p_date date default null, p_consultant text default null)
returns jsonb
language sql
stable security definer
set search_path to 'public'
as $function$
  with today as (select (now() at time zone 'Europe/London')::date t),
  d as (
    select coalesce(p_date, case extract(isodow from t)::int
      when 1 then t - 3 when 7 then t - 2 when 6 then t - 1 else t - 1 end) as day
    from today
  ),
  moved as (
    select distinct on (e.candidate_slug, e.job_slug, e.stage_metric)
      e.candidate_slug, e.job_slug, e.stage_metric, e.candidate_name, e.job_title, e.consultant
    from candidate_stage_events e, d
    where e.event_date = d.day and e.stage_metric in ('cv_sent', 'interview_request')
      and (p_consultant is null or e.consultant ilike '%' || p_consultant || '%')
    order by e.candidate_slug, e.job_slug, e.stage_metric, e.event_timestamp desc
  ),
  cur as (
    select distinct on (x.candidate_slug, x.job_slug) x.candidate_slug, x.job_slug, x.stage_name, x.event_date
    from candidate_stage_events x join (select distinct candidate_slug, job_slug from moved) m using (candidate_slug, job_slug)
    order by x.candidate_slug, x.job_slug, x.event_timestamp desc
  ),
  rows as (
    select m.stage_metric, jsonb_build_object(
        'candidate', m.candidate_name, 'company', c.company_name, 'job', coalesce(j.title, m.job_title),
        'current_stage', cur.stage_name, 'current_stage_date', cur.event_date, 'by', m.consultant) as r,
      m.consultant, m.candidate_name
    from moved m
    left join cur using (candidate_slug, job_slug)
    left join jobs j on j.slug = m.job_slug
    left join clients c on c.id = j.client_id
  )
  select jsonb_build_object(
    'date', (select day from d),
    'definition', 'Candidates moved to CV Sent or Interview Request on this day, credited to whoever moved them, with each one''s current stage now. Same counting as the funnel.',
    'cv_sent', coalesce((select jsonb_agg(r order by consultant, candidate_name) from rows where stage_metric = 'cv_sent'), '[]'::jsonb),
    'interview_requests', coalesce((select jsonb_agg(r order by consultant, candidate_name) from rows where stage_metric = 'interview_request'), '[]'::jsonb),
    'by_consultant', coalesce((select jsonb_agg(jsonb_build_object('name', consultant, 'cv_sent', cv, 'interview_requests', ivr) order by cv + ivr desc, consultant)
      from (select consultant, count(*) filter (where stage_metric = 'cv_sent') cv, count(*) filter (where stage_metric = 'interview_request') ivr from rows group by consultant) s), '[]'::jsonb),
    'totals', jsonb_build_object('cv_sent', (select count(*) from rows where stage_metric = 'cv_sent'),
                                 'interview_requests', (select count(*) from rows where stage_metric = 'interview_request'))
  );
$function$;
revoke execute on function public.daily_activity(date, text) from public, anon, authenticated;
