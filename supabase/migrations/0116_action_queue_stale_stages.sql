-- 0116_action_queue_stale_stages.sql
-- First shadow run, 26/10/2026: Will's, Adam's and Keelan's queues led with offers out 41, 33 and 25
-- days and interview requests unbooked for 27 days. Those are stages nobody updated, not live work, and
-- they pushed real calls down the list. Decided the same day: offers count up to 21 days, unbooked
-- requests up to 14; anything older goes into one closing "clean up these stages" line, with the
-- first five names, after the ranked items. Otherwise identical to 0115.

create or replace function public.action_queue(p_consultant bigint)
returns jsonb language sql stable security definer set search_path = public, pg_temp
as $function$
  with me as (select recruitcrm_id, name from consultants where recruitcrm_id = p_consultant and deleted_at is null),
  wd5 as (   -- the date five working days ago
    select d::date d from generate_series(current_date - 14, current_date - 1, interval '1 day') d
    where extract(isodow from d) < 6 order by d desc offset 4 limit 1
  ),
  dd as (select x from jsonb_array_elements(public.diary_digest()->'by_consultant') x, me where x->>'consultant' = me.name),
  offers as (
    select 1 rank, 'offer' kind, x->>'candidate' who, x->>'job_title' job, null::text client,
           (x->>'days_since_offer')::int age, 'Offer out '||(x->>'days_since_offer')||' days: call the candidate, then the client' action
    from jsonb_array_elements(public.stalled_report(10, 3, 60)->'aging_offers') x, me
    where x->>'consultant' = me.name and (x->>'days_since_offer')::int <= 21
  ),
  prep as (
    select 2, 'prep', p->>'candidate', p->>'job', p->>'client', 0,
           'Interview '||to_char((select (public.diary_digest()->>'prep_day')::date), 'Dy')||' '||(p->>'time')||': prep call'
    from dd, jsonb_array_elements(dd.x->'prep') p
  ),
  fb as (
    select 3, 'feedback', f->>'candidate', f->>'job', f->>'client', 0,
           'Interviewed '||(f->>'held')||', nothing logged since: feedback call to the client'
    from dd, jsonb_array_elements(dd.x->'feedback_due') f
  ),
  unbooked as (
    select 4, 'unbooked', x->>'candidate', x->>'job', null::text, (x->>'days_waiting')::int,
           'Interview request '||(x->>'days_waiting')||' days unbooked: booking call'
    from jsonb_array_elements(public.interview_requests_unbooked(30)->'requests') x, me
    where x->>'consultant' = me.name and (x->>'days_waiting')::int between 2 and 14
  ),
  -- 0116: offers older than 21 days and requests unbooked for over 14 are almost always stages nobody
  -- updated, not live work, so they make one clean-up line instead of leading the list.
  stale as (
    select x->>'candidate' who, (x->>'days_since_offer')::int age from jsonb_array_elements(public.stalled_report(10, 3, 60)->'aging_offers') x, me
    where x->>'consultant' = me.name and (x->>'days_since_offer')::int > 21
    union all
    select x->>'candidate', (x->>'days_waiting')::int from jsonb_array_elements(public.interview_requests_unbooked(30)->'requests') x, me
    where x->>'consultant' = me.name and (x->>'days_waiting')::int > 14
  ),
  latest as (
    select distinct on (e.candidate_slug, e.job_slug) e.candidate_name, e.job_title, e.stage_metric, e.event_date, e.consultant
    from candidate_stage_events e join jobs j on j.slug = e.job_slug and j.status = 'Open' and j.deleted_at is null
    where e.event_date >= current_date - 30
    order by e.candidate_slug, e.job_slug, e.event_timestamp desc
  ),
  cvs as (
    select 5, 'cv_chase', l.candidate_name, l.job_title, null::text, (current_date - l.event_date),
           'CV sent '||to_char(l.event_date, 'DD/MM')||', no response: chase call'
    from latest l, me, wd5 where l.stage_metric = 'cv_sent' and l.consultant = me.name and l.event_date <= wd5.d
  ),
  cold as (
    select 6, 'cold_job', null::text, x->>'job_title', x->>'client', (x->>'days_since_activity')::int,
           'Cold '||(x->>'days_since_activity')||' days: Boolean search, shortlist and InMails'
    from jsonb_array_elements(public.cold_jobs(7, null, 100)->'jobs') x, me where x->>'consultant' = me.name
  ),
  bd as (
    select 7, 'bd', null::text, null::text, null::text, 0,
           'BD calls: '||n||' tagged this week against 5. A prospect list and spec pitches would close the gap'
    from (select count(*) n from call_activity ca, me
          where ca.consultant_recruitcrm_id = me.recruitcrm_id and ca.custom_call_type = 'Contact - Prospect (BD)'
            and (ca.call_started_on at time zone 'Europe/London')::date >= date_trunc('week', current_date)::date) c
    where extract(isodow from current_date) between 2 and 5 and n < extract(isodow from current_date) - 1
  ),
  allrows as (
    select * from offers union all select * from prep union all select * from fb union all select * from unbooked
    union all select * from cvs union all select * from cold union all select * from bd
  ),
  numbered as (
    select a.*, row_number() over (partition by kind order by age desc nulls last, who) n_in_kind from allrows a
  ),
  capped as (
    select * from numbered
    where n_in_kind <= case kind when 'unbooked' then 3 when 'cv_chase' then 3 when 'cold_job' then 2 when 'bd' then 1 else 1000 end
    order by rank, age desc nulls last, who limit 10
  )
  select jsonb_build_object(
    'consultant', (select name from me),
    'for_date', current_date,
    'total', (select count(*) from allrows),
    'by_kind', (select coalesce(jsonb_object_agg(kind, n), '{}'::jsonb) from (select kind, count(*) n from allrows group by kind) k),
    'stale_stages', (select count(*) from stale),
    'items', coalesce((select jsonb_agg(jsonb_build_object('kind', kind, 'action', action, 'who', who, 'job', job, 'client', client)
                         order by rank, age desc nulls last, who) from capped), '[]'::jsonb)
      || case when exists (select 1 from stale) then jsonb_build_array(jsonb_build_object('kind', 'cleanup',
           'action', (select count(*) from stale)||' stages look out of date (offers over 21 days, interview requests unbooked over 14): update or close them in RecruitCRM',
           'who', (select string_agg(who, ', ' order by age desc) from (select who, age from stale order by age desc limit 5) t)
                  || case when (select count(*) from stale) > 5 then ', …' else '' end,
           'job', null, 'client', null)) else '[]'::jsonb end);
$function$;
revoke execute on function public.action_queue(bigint) from public, anon, authenticated;
grant execute on function public.action_queue(bigint) to service_role;
