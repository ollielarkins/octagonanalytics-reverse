-- End-of-week team email for Dale (octagon-mcp eow_email).
--
-- One window, end-exclusive (default: this week, Monday to tomorrow, for a Friday send). Counting
-- matches kpis_report so the email and /week agree: stage counts come from candidate_stage_latest
-- (each candidate-job pair once, at the last time it entered the stage, credited to whoever made
-- that move); BD calls are categorised Devyce 'Contact - Prospect (BD)' calls by the caller.
-- Interviews = distinct candidate-job pairs reaching 1st, 2nd or 3rd interview in the window.
-- Checked against Dale's email for 05/10-11/10/2026: every figure matched except one interview
-- credited to Georgia (who moved it) rather than Dale.
--
-- "Candidates assigned" is not here: the sync drops the Assigned stage (id 1), so it is not in the
-- data. Rows with no activity at all are left out, as in Dale's own table; leavers are tagged.
create or replace function public.eow_report(p_from date default date_trunc('week', current_date)::date,
                                             p_to date default (current_date + 1))
returns jsonb language sql stable security definer set search_path to 'public' as $function$
  with ev as (
    select e.consultant_id rid,
      count(*) filter (where e.stage_metric = 'cv_sent') cv,
      count(*) filter (where e.stage_metric = 'interview_request') ir,
      count(distinct (e.candidate_slug, e.job_slug)) filter (where e.stage_metric in ('first_interview','second_interview','third_interview')) iv,
      count(*) filter (where e.stage_metric = 'offered') off
    from candidate_stage_latest e
    join jobs j on j.slug = e.job_slug and j.deleted_at is null
    where e.event_date >= p_from and e.event_date < p_to
    group by 1),
  cl as (
    select consultant_recruitcrm_id rid, count(*) filter (where custom_call_type = 'Contact - Prospect (BD)') bd
    from call_activity where call_date >= p_from and call_date < p_to group by 1),
  jb as (
    select c.recruitcrm_id rid, count(*) n from jobs j join consultants c on c.id = j.consultant_id
    where j.created_date >= p_from and j.created_date < p_to and j.deleted_at is null group by 1),
  rows as (
    select c.name, not (c.deleted_at is null and c.active) as left_, coalesce(jb.n,0) jobs_added, coalesce(ev.cv,0) cv_sent,
      coalesce(ev.ir,0) interview_requests, coalesce(ev.iv,0) interviews, coalesce(ev.off,0) offers, coalesce(cl.bd,0) bd_calls
    from consultants c
    left join ev on ev.rid = c.recruitcrm_id left join cl on cl.rid = c.recruitcrm_id left join jb on jb.rid = c.recruitcrm_id
    where coalesce(jb.n,0) + coalesce(ev.cv,0) + coalesce(ev.ir,0) + coalesce(ev.iv,0) + coalesce(ev.off,0) + coalesce(cl.bd,0) > 0),
  offers as (
    select * from candidate_stage_latest where stage_metric = 'offered' and event_date >= p_from and event_date < p_to),
  cur as (
    select distinct on (e.candidate_slug, e.job_slug) e.candidate_slug, e.job_slug, e.stage_name, e.event_date
    from candidate_stage_events e join offers o using (candidate_slug, job_slug)
    order by e.candidate_slug, e.job_slug, e.event_timestamp desc nulls last, e.event_date desc)
  select jsonb_build_object(
    'window', jsonb_build_object('from', p_from, 'to_exclusive', p_to),
    'consultants', (select coalesce(jsonb_agg(to_jsonb(r) - 'left_' || jsonb_build_object('left', r.left_)
                     order by r.left_, r.cv_sent desc, r.interview_requests desc, r.name), '[]'::jsonb) from rows r),
    'totals', (select jsonb_build_object('jobs_added', coalesce(sum(jobs_added),0), 'cv_sent', coalesce(sum(cv_sent),0),
                 'interview_requests', coalesce(sum(interview_requests),0), 'interviews', coalesce(sum(interviews),0),
                 'offers', coalesce(sum(offers),0), 'bd_calls', coalesce(sum(bd_calls),0)) from rows),
    'offers', (select coalesce(jsonb_agg(jsonb_build_object('candidate', o.candidate_name, 'company', cl.company_name, 'job', o.job_title,
                 'current_stage', cur.stage_name, 'current_stage_date', cur.event_date, 'offered_by', o.consultant) order by o.event_date desc), '[]'::jsonb)
               from offers o join cur using (candidate_slug, job_slug)
               left join jobs j on j.slug = o.job_slug left join clients cl on cl.id = j.client_id),
    'jobs', (select coalesce(jsonb_agg(jsonb_build_object('slug', j.slug, 'title', j.title, 'company', cl.company_name, 'status', j.status,
                 'date_added', j.created_date::date, 'owner', c.name) order by j.created_date), '[]'::jsonb)
             from jobs j left join clients cl on cl.id = j.client_id left join consultants c on c.id = j.consultant_id
             where j.created_date >= p_from and j.created_date < p_to and j.deleted_at is null)
  );
$function$;

revoke all on function public.eow_report(date, date) from public, anon, authenticated;
grant execute on function public.eow_report(date, date) to service_role;
