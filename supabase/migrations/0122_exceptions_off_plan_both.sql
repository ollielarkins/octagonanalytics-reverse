-- 0122_exceptions_off_plan_both.sql
-- 0121's off-plan rule (below half the plan on any of CVs, interview requests or interviews) flagged 7 of
-- 8 consultants for the week of 19/10/2026: a team-wide gap, not exceptions. Decided 26/10/2026: off plan
-- only when below half on BOTH CVs and interviews, so only real outliers show. Otherwise identical to 0121.
create or replace function public.team_exceptions()
returns jsonb language sql stable security definer set search_path = public, pg_temp
as $function$
  with lw as (select (date_trunc('week', current_date) - interval '7 days')::date ws, date_trunc('week', current_date)::date we),
  plan as (select x from jsonb_array_elements(public.weekly_plan()->'consultants') x),
  people as (select c.recruitcrm_id, c.name from consultants c where c.deleted_at is null and coalesce(c.active, true)
    and c.recruitcrm_id::text <> all (string_to_array(coalesce((select value from app_settings where key = 'exceptions_exclude_ids'), ''), ','))),
  last_week as (
    select e.consultant, e.stage_metric, count(distinct e.candidate_slug||'|'||e.job_slug) n
    from candidate_stage_events e join jobs j on j.slug = e.job_slug and j.deleted_at is null, lw
    where e.event_date >= lw.ws and e.event_date < lw.we group by 1, 2
  ),
  win as (
    select e.consultant,
           count(distinct e.candidate_slug||'|'||e.job_slug) filter (where e.stage_metric='cv_sent' and e.event_date >= current_date - 56) cv8,
           count(distinct e.candidate_slug||'|'||e.job_slug) filter (where e.stage_metric='first_interview' and e.event_date >= current_date - 56) iv8,
           count(distinct e.candidate_slug||'|'||e.job_slug) filter (where e.stage_metric='offered' and e.event_date >= current_date - 56) of8,
           count(distinct e.candidate_slug||'|'||e.job_slug) filter (where e.stage_metric='cv_sent' and e.event_date < current_date - 56) cvp,
           count(distinct e.candidate_slug||'|'||e.job_slug) filter (where e.stage_metric='first_interview' and e.event_date < current_date - 56) ivp,
           count(distinct e.candidate_slug||'|'||e.job_slug) filter (where e.stage_metric='offered' and e.event_date < current_date - 56) ofp
    from candidate_stage_events e join jobs j on j.slug = e.job_slug and j.deleted_at is null
    where e.event_date >= current_date - 56 - 182 group by 1
  ),
  q as (select greatest(1, ((current_date - date_trunc('quarter', current_date)::date) / 7) + 1) wk),
  ex_rows as (
    select p.name,
      -- off plan, last full week: below half the plan on BOTH CVs and interviews (0122)
      (select case when s.cv_a < 0.5 * s.cv_p and s.iv_a < 0.5 * s.iv_p
                   then jsonb_build_array(format('CVs %s of %s', s.cv_a, s.cv_p), format('interviews %s of %s', s.iv_a, s.iv_p)) end
         from (select coalesce((select n from last_week lw2 where lw2.consultant = p.name and lw2.stage_metric = 'cv_sent'), 0) cv_a,
                      (pl.x->'plan'->>'cv_sent')::numeric cv_p,
                      coalesce((select n from last_week lw2 where lw2.consultant = p.name and lw2.stage_metric = 'first_interview'), 0) iv_a,
                      (pl.x->'plan'->>'first_interview')::numeric iv_p
               from plan pl where pl.x->>'consultant' = p.name) s) off_plan,
      -- backlog
      (select case when (q->>'total')::int >= 25 or (q->>'stale_stages')::int >= 3
                   then format('%s calls on their queue, %s stages out of date', q->>'total', q->>'stale_stages') end
         from (select public.action_queue(p.recruitcrm_id) q) t) backlog,
      -- ratios
      (select jsonb_agg(m) from (
         select format('CV to interview %s%% (was %s%%)', round(100.0 * w.iv8 / w.cv8, 1), round(100.0 * w.ivp / nullif(w.cvp, 0), 1)) m
         where w.cv8 >= 20 and w.cvp >= 20 and (w.iv8::numeric / w.cv8) < 0.7 * (w.ivp::numeric / w.cvp)
         union all
         select format('interview to offer %s%% (was %s%%)', round(100.0 * w.of8 / w.iv8, 1), round(100.0 * w.ofp / nullif(w.ivp, 0), 1))
         where w.iv8 >= 10 and w.ivp >= 10 and (w.of8::numeric / w.iv8) < 0.7 * (w.ofp::numeric / w.ivp)) s) ratios,
      -- client visits against the quarter's pace
      (select case when (select wk from q) >= 4
                     and (cv->>'visits_done')::int + (cv->>'visits_booked')::int < floor(2.0 * (select wk from q) / 13)
                   then format('%s client visits done, %s booked, week %s of 13%s', cv->>'visits_done', cv->>'visits_booked', (select wk from q),
                               case when (cv->>'untyped_meetings')::int > 0 then format(' (%s meetings untyped)', cv->>'untyped_meetings') else '' end) end
         from (select c from jsonb_array_elements(public.client_visits(p.recruitcrm_id)->'consultants') c) t(cv)) visits
    from people p left join win w on w.consultant = p.name
  )
  select jsonb_build_object(
    'as_of', current_date, 'last_week', (select jsonb_build_object('from', ws, 'to_exclusive', we) from lw),
    'rules', 'Off plan: last full week below half the plan on both CVs and interviews. Backlog: 25+ calls queued or 3+ stages out of date. Ratios: last 8 weeks more than 30% below the previous 6 months, with enough volume. Visits: below the pace for 2 per quarter, from week 4.',
    'exceptions', coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object('consultant', name, 'off_plan', off_plan, 'backlog', backlog,
                     'ratios', ratios, 'visits', visits)) order by name)
                   from ex_rows where off_plan is not null or backlog is not null or ratios is not null or visits is not null), '[]'::jsonb),
    'clear', coalesce((select jsonb_agg(name order by name) from ex_rows
                       where off_plan is null and backlog is null and ratios is null and visits is null), '[]'::jsonb));
$function$;

revoke execute on function public.team_exceptions() from public, anon, authenticated;
grant execute on function public.team_exceptions() to service_role;
