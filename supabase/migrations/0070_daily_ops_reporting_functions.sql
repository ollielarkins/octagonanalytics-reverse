-- 0070_daily_ops_reporting_functions.sql
-- Data layer for the daily-ops commands. Five reports that had no function behind them.
-- Each was validated against live data before being written; the counts in the comments are
-- from the window 10/08/2026-07/09/2026 and are there so a future reader can tell whether a
-- function has silently started returning nothing.
--
-- These are NOT yet reachable from the recruiter-facing assistant: octagon-mcp has to expose
-- them as tools and that needs a CLI deploy. The SQL is applied and correct either way.

-- 1. Calls split by hour of day (Europe/London), so "evening calls" is answerable.
--    Validated: 295 calls at/after 17:00 in the four-week window (6.8% of 4,352).
create or replace function public.call_hours_report(
  p_from date default (current_date - 7),
  p_to   date default (current_date + 1),
  p_consultant text default null,
  p_evening_from integer default 17
)
returns jsonb language sql stable security definer set search_path to 'public'
as $function$
  with c as (
    select a.consultant,
           extract(hour from a.call_started_on at time zone 'Europe/London')::int hr,
           a.connected, a.custom_call_type
    from call_activity a
    where a.call_date >= p_from and a.call_date < p_to
      and (p_consultant is null or a.consultant ilike '%'||p_consultant||'%')
  )
  select jsonb_build_object(
    'window', jsonb_build_object('from', p_from, 'to', p_to, 'evening_from_hour', p_evening_from),
    'definition', 'Calls bucketed by hour of day in Europe/London. "Evening" is any call at or after evening_from_hour. Attributed to the caller. Counts ALL calls, categorised or not, so unlike the BD/client KPIs it does not depend on tagging.',
    'totals', (select jsonb_build_object(
        'calls', count(*),
        'connected', count(*) filter (where connected),
        'evening_calls', count(*) filter (where hr >= p_evening_from),
        'evening_connected', count(*) filter (where hr >= p_evening_from and connected),
        'evening_pct', round(100.0*count(*) filter (where hr >= p_evening_from)/nullif(count(*),0),1)) from c),
    'by_hour', (select coalesce(jsonb_agg(jsonb_build_object('hour', hr, 'calls', n, 'connected', conn) order by hr), '[]'::jsonb)
      from (select hr, count(*) n, count(*) filter (where connected) conn from c group by hr) h),
    'by_consultant', (select coalesce(jsonb_agg(jsonb_build_object(
        'name', consultant, 'calls', n, 'evening_calls', ev, 'evening_connected', evc) order by ev desc, n desc), '[]'::jsonb)
      from (select consultant, count(*) n,
                   count(*) filter (where hr >= p_evening_from) ev,
                   count(*) filter (where hr >= p_evening_from and connected) evc
            from c where consultant is not null group by consultant) b)
  );
$function$;

-- 2. New jobs added, and whether a Job Order Form Complete note exists on each.
--    Validated: 36 new jobs in the window, 9 with a form, 27 without (25.0% completion).
create or replace function public.new_jobs_report(
  p_from date default (current_date - 7),
  p_to   date default (current_date + 1),
  p_consultant text default null
)
returns jsonb language sql stable security definer set search_path to 'public'
as $function$
  with nj as (
    select j.slug, j.title, j.status, j.created_date::date created,
           coalesce(co.name, '(unassigned)') owner,
           exists (select 1 from notes n
                   where n.related_to_type = 'job' and n.related_to = j.slug
                     and n.note_type = 'Job Order Form Complete') as job_order_form
    from jobs j
    left join consultants co on co.id = j.consultant_id
    where j.deleted_at is null
      and j.created_date >= p_from and j.created_date < p_to
      and (p_consultant is null or co.name ilike '%'||p_consultant||'%')
  )
  select jsonb_build_object(
    'window', jsonb_build_object('from', p_from, 'to', p_to),
    'definition', 'Jobs created in the window, with whether a "Job Order Form Complete" note has been logged against the job. Absence means the note was never logged - it does not prove the qualifying call did not happen.',
    'totals', (select jsonb_build_object(
        'new_jobs', count(*),
        'with_job_order_form', count(*) filter (where job_order_form),
        'missing_job_order_form', count(*) filter (where not job_order_form),
        'form_completion_pct', round(100.0*count(*) filter (where job_order_form)/nullif(count(*),0),1)) from nj),
    'by_consultant', (select coalesce(jsonb_agg(jsonb_build_object(
        'name', owner, 'new_jobs', n, 'with_form', wf, 'missing_form', n - wf) order by n desc), '[]'::jsonb)
      from (select owner, count(*) n, count(*) filter (where job_order_form) wf from nj group by owner) b),
    'jobs', (select coalesce(jsonb_agg(jsonb_build_object(
        'title', title, 'owner', owner, 'status', status,
        'created', created, 'job_order_form', job_order_form) order by created desc), '[]'::jsonb) from nj)
  );
$function$;

-- 3. Interview requests never booked in.
--    Validated: 481 all-time, 23 in the last 30 days, 14 in the last 7.
--    The all-time figure is mostly abandoned history - default to a recent window.
create or replace function public.interview_requests_unbooked(
  p_within_days integer default 30,
  p_consultant text default null
)
returns jsonb language sql stable security definer set search_path to 'public'
as $function$
  with ir as (
    select e.candidate_slug, e.job_slug, max(e.event_timestamp) ts
    from candidate_stage_events e
    join jobs j on j.slug = e.job_slug and j.deleted_at is null
    where e.stage_metric = 'interview_request'
    group by 1,2
  ),
  open_ir as (
    select ir.*, (select ev.consultant from candidate_stage_events ev
                  where ev.candidate_slug=ir.candidate_slug and ev.job_slug=ir.job_slug
                    and ev.stage_metric='interview_request'
                  order by ev.event_timestamp desc limit 1) as consultant
    from ir
    where ir.ts >= now() - make_interval(days => p_within_days)
      and not exists (select 1 from candidate_stage_events f
            where f.candidate_slug=ir.candidate_slug and f.job_slug=ir.job_slug
              and f.stage_metric in ('first_interview','second_interview','third_interview','offered','placed')
              and f.event_timestamp > ir.ts)
      and not exists (select 1 from candidate_stage_events r
            where r.candidate_slug=ir.candidate_slug and r.job_slug=ir.job_slug
              and r.stage_metric in ('rejected_client','rejected_consultant')
              and r.event_timestamp > ir.ts)
  ),
  d as (
    select o.*, j.title job_title, (now()::date - o.ts::date) days_waiting,
           trim(coalesce(c.first_name,'')||' '||coalesce(c.last_name,'')) candidate
    from open_ir o
    left join jobs j on j.slug=o.job_slug
    left join candidates c on c.slug=o.candidate_slug
    where (p_consultant is null or o.consultant ilike '%'||p_consultant||'%')
  )
  select jsonb_build_object(
    'window', jsonb_build_object('within_days', p_within_days),
    'definition', 'Interview requests with no interview, offer, placement or rejection recorded since. Counted per candidate-job pair at the latest request, credited to whoever made it. Older than the window is excluded as abandoned rather than outstanding.',
    'total', (select count(*) from d),
    'by_consultant', (select coalesce(jsonb_agg(jsonb_build_object('name', consultant, 'waiting', n) order by n desc), '[]'::jsonb)
      from (select consultant, count(*) n from d where consultant is not null group by consultant) b),
    'requests', (select coalesce(jsonb_agg(jsonb_build_object(
        'candidate', candidate, 'job', job_title, 'consultant', consultant,
        'requested', ts::date, 'days_waiting', days_waiting) order by days_waiting desc), '[]'::jsonb) from d)
  );
$function$;

-- 4. Candidates interviewed with no feedback logged since.
--    Validated: 698 all-time, 26 in the last 30 days, 12 in the last 14.
create or replace function public.awaiting_feedback_report(
  p_min_days integer default 2,
  p_within_days integer default 30,
  p_consultant text default null
)
returns jsonb language sql stable security definer set search_path to 'public'
as $function$
  with iv as (
    select e.candidate_slug, e.job_slug, max(e.event_timestamp) ts
    from candidate_stage_events e
    join jobs j on j.slug = e.job_slug and j.deleted_at is null
    where e.stage_metric in ('first_interview','second_interview','third_interview')
    group by 1,2
  ),
  waiting as (
    select iv.*, (select ev.consultant from candidate_stage_events ev
                  where ev.candidate_slug=iv.candidate_slug and ev.job_slug=iv.job_slug
                  order by ev.event_timestamp desc limit 1) consultant
    from iv
    where iv.ts < now() - make_interval(days => p_min_days)
      and iv.ts >= now() - make_interval(days => p_within_days)
      and not exists (select 1 from candidate_stage_events n
            where n.candidate_slug=iv.candidate_slug and n.job_slug=iv.job_slug
              and n.stage_metric in ('offered','placed','rejected_client','rejected_consultant')
              and n.event_timestamp > iv.ts)
      and not exists (select 1 from call_activity c
            where c.related_to = iv.candidate_slug
              and c.custom_call_type = 'Interview Feedback' and c.call_started_on > iv.ts)
      and not exists (select 1 from notes nt
            where nt.related_to = iv.candidate_slug and nt.related_to_type = 'candidate'
              and nt.created_on > iv.ts)
  ),
  d as (
    select w.*, j.title job_title, (now()::date - w.ts::date) days_since,
           trim(coalesce(c.first_name,'')||' '||coalesce(c.last_name,'')) candidate
    from waiting w
    left join jobs j on j.slug=w.job_slug
    left join candidates c on c.slug=w.candidate_slug
    where (p_consultant is null or w.consultant ilike '%'||p_consultant||'%')
  )
  select jsonb_build_object(
    'window', jsonb_build_object('min_days', p_min_days, 'within_days', p_within_days),
    'definition', 'Candidates interviewed at least min_days ago with nothing logged since - no Interview Feedback call, no candidate note, and no move to offered, placed or rejected. Silence in the system, which is not the same as no feedback having been given.',
    'total', (select count(*) from d),
    'by_consultant', (select coalesce(jsonb_agg(jsonb_build_object('name', consultant, 'awaiting', n) order by n desc), '[]'::jsonb)
      from (select consultant, count(*) n from d where consultant is not null group by consultant) b),
    'candidates', (select coalesce(jsonb_agg(jsonb_build_object(
        'candidate', candidate, 'job', job_title, 'consultant', consultant,
        'interviewed', ts::date, 'days_since', days_since) order by days_since desc), '[]'::jsonb) from d)
  );
$function$;

-- 5. Placements with the money attached, from deals rather than the empty placements table.
--    deals carries annual_salary, fee_percentage and deal_value; there is NO invoices table, so
--    invoice confirmation is not answerable here and the definition says so rather than implying it.
--
--    Worth flagging: for 01/08-08/09/2026 this returns 11 placements worth GBP 92,045, where the
--    existing placements_report returns the same 11 placements but GBP 5,250 of revenue. The
--    difference is the join. placements_report sums Won deals by close_date inside the window;
--    only ONE Won deal has a close_date in that range because deals are routinely marked Won with
--    a FORWARD close date. This function instead joins each placement to its job's Won deal
--    whenever that deal closes. Neither is wrong in the abstract - they answer different questions
--    (cash landing in the window vs value of what was placed in the window) - but placements_report
--    presents its figure as "Won revenue" without saying which, and that reads as billing. The
--    firm still needs to settle which one billing means; see the three-definitions-of-placed issue.
create or replace function public.placements_with_fees(
  p_from date default (date_trunc('month', current_date))::date,
  p_to   date default (current_date + 1),
  p_consultant text default null
)
returns jsonb language sql stable security definer set search_path to 'public'
as $function$
  with placed as (
    select e.candidate_slug, e.job_slug, max(e.event_date) placed_on,
           (select ev.consultant from candidate_stage_events ev
            where ev.candidate_slug=e.candidate_slug and ev.job_slug=e.job_slug
              and ev.stage_metric='placed' order by ev.event_timestamp desc limit 1) consultant
    from candidate_stage_events e
    join jobs j on j.slug=e.job_slug and j.deleted_at is null
    where e.stage_metric='placed' and e.event_date >= p_from and e.event_date < p_to
    group by e.candidate_slug, e.job_slug
  ),
  enriched as (
    select p.*, j.title job_title,
           d.deal_value, d.fee_percentage, d.annual_salary, d.close_date::date close_date, d.deal_stage
    from placed p
    left join jobs j on j.slug=p.job_slug
    left join lateral (
      select dd.* from deals dd
      where dd.job_slug = p.job_slug and dd.deal_stage ilike '%won%'
      order by dd.close_date desc nulls last limit 1) d on true
    where (p_consultant is null or p.consultant ilike '%'||p_consultant||'%')
  )
  select jsonb_build_object(
    'window', jsonb_build_object('from', p_from, 'to', p_to),
    'definition', 'Placed stage events in the window, joined to the job''s Won deal for the money. Fee data comes from deals (annual_salary, fee_percentage, deal_value). There is NO invoices table mirrored, so invoice status cannot be confirmed here - check RecruitCRM directly. A placement with no matching Won deal shows null value: that is a deal not yet moved to Won, not a missing placement.',
    'totals', (select jsonb_build_object(
        'placed', count(*),
        'with_won_deal', count(*) filter (where deal_value is not null),
        'missing_won_deal', count(*) filter (where deal_value is null),
        'total_value', coalesce(sum(deal_value),0)) from enriched),
    'by_consultant', (select coalesce(jsonb_agg(jsonb_build_object(
        'name', consultant, 'placed', n, 'value', val) order by val desc nulls last, n desc), '[]'::jsonb)
      from (select consultant, count(*) n, coalesce(sum(deal_value),0) val
            from enriched where consultant is not null group by consultant) b),
    'placements', (select coalesce(jsonb_agg(jsonb_build_object(
        'candidate_job', job_title, 'consultant', consultant, 'placed_on', placed_on,
        'deal_value', deal_value, 'fee_pct', fee_percentage, 'annual_salary', annual_salary,
        'deal_close_date', close_date) order by placed_on desc), '[]'::jsonb) from enriched)
  );
$function$;

revoke all on function public.call_hours_report(date,date,text,integer) from public, anon;
revoke all on function public.new_jobs_report(date,date,text) from public, anon;
revoke all on function public.interview_requests_unbooked(integer,text) from public, anon;
revoke all on function public.awaiting_feedback_report(integer,integer,text) from public, anon;
revoke all on function public.placements_with_fees(date,date,text) from public, anon;
grant execute on function public.call_hours_report(date,date,text,integer) to service_role, authenticated;
grant execute on function public.new_jobs_report(date,date,text) to service_role, authenticated;
grant execute on function public.interview_requests_unbooked(integer,text) to service_role, authenticated;
grant execute on function public.awaiting_feedback_report(integer,integer,text) to service_role, authenticated;
grant execute on function public.placements_with_fees(date,date,text) to service_role, authenticated;
