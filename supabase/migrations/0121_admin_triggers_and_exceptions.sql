-- 0121_admin_triggers_and_exceptions.sql
-- Priority 7 (Bhav, 20/10/2026): admin drafts triggered by events, nothing sent until the consultant
-- approves. Under the 13/10/2026 rule of no server-side AI the server cannot write the drafts, so the
-- events go into the consultant's 08:30 queue and their own Claude drafts them in one step:
--   * new job (last 3 days): "kick it off" = advert, Boolean, matched shortlist, DPE email
--   * candidate rejected by the client (last 4 days, no note since): the candidate update email
--   * Friday: Push & Tell for clients with A and B grade jobs not yet sent this week (closing line)
-- Priority 8 (Bhav): a manager view, exceptions only. team_exceptions() lists only people with
-- something to act on: off plan last week, a backlog of actions, ratios falling, behind on client
-- visits for the point in the quarter. Sent as a Monday DM to app_settings.manager_exceptions_emails.

-- action_queue: two new call kinds and the Friday Push & Tell line. Guarded multi-part edit.
do $do$
declare
  def text := pg_get_functiondef('public.action_queue(bigint)'::regprocedure);
  a1 text := $a$  allrows as ($a$;
  n1 text := $b$  -- 0121: new jobs to kick off, and client rejections with nothing logged since.
  newjobs as (
    select 3, 'new_job', 'newjob:'||j.slug, null::text, j.title, cl.company_name, null::text, j.slug, (current_date - j.created_date::date),
           'New job '||to_char(j.created_date, 'DD/MM')||': ask Claude to kick it off (advert, Boolean, shortlist, DPE email)'
    from jobs j join consultants co on co.id = j.consultant_id join me on me.recruitcrm_id = co.recruitcrm_id
    left join clients cl on cl.company_slug = j.company_slug
    where j.deleted_at is null and j.status = 'Open' and j.created_date >= current_date - 3
  ),
  rejected as (
    select 4, 'rejected', 'rejected:'||e.candidate_slug||':'||e.job_slug, e.candidate_name, e.job_title, null::text, e.candidate_slug, e.job_slug,
           (current_date - e.event_date), 'Rejected by the client '||to_char(e.event_date, 'DD/MM')||': ask Claude to draft the candidate update'
    from (select distinct on (candidate_slug, job_slug) * from candidate_stage_events
          where stage_metric = 'rejected_client' and event_date >= current_date - 4
          order by candidate_slug, job_slug, event_timestamp desc) e, me
    where e.consultant = me.name
      and not exists (select 1 from notes n where n.related_to = e.candidate_slug and n.created_on >= (e.event_timestamp at time zone 'UTC'))
  ),
  pushtell as (
    select count(distinct j.company_slug) n from jobs j join consultants co on co.id = j.consultant_id join me on me.recruitcrm_id = co.recruitcrm_id
    where j.deleted_at is null and j.status = 'Open' and j.custom_fields->'13'->>'value' in ('A','B')
      and coalesce(left(j.custom_fields->'44'->>'value', 10), '') < to_char(date_trunc('week', current_date), 'YYYY-MM-DD')
  ),
  allrows as ($b$;
  a2 text := $a$      union all select * from cvs union all select * from cold union all select * from bd) a$a$;
  n2 text := $b$      union all select * from cvs union all select * from cold union all select * from bd
      union all select * from newjobs union all select * from rejected) a$b$;
  a3 text := $a$when 'bd' then 1 else 1000 end$a$;
  n3 text := $b$when 'bd' then 1 when 'new_job' then 3 when 'rejected' then 3 else 1000 end$b$;
  a4 text := $a$    union all
    select 3, jsonb_build_object('kind', 'client_visits'$a$;
  n4 text := $b$    union all
    select 4, jsonb_build_object('kind', 'pushtell', 'item_key', 'pushtell:'||to_char(current_date, 'IYYY-IW'),
           'action', 'Push & Tell: '||n||case when n = 1 then ' client' else ' clients' end||' with A or B grade jobs still to update this week: ask Claude to do my Push & Tell',
           'who', null)
    from pushtell where n > 0 and extract(isodow from current_date) = 5
    union all
    select 3, jsonb_build_object('kind', 'client_visits'$b$;
  k text;
begin
  if position('newjobs as (' in def) > 0 then
    return;   -- already applied
  end if;
  foreach k in array array[a1, a2, a3, a4] loop
    if (length(def) - length(replace(def, k, ''))) / length(k) <> 1 then
      raise exception '0121: action_queue anchor not found exactly once (%); it has changed since 0120', left(k, 40);
    end if;
  end loop;
  def := replace(def, a1, n1);
  def := replace(def, a2, n2);
  def := replace(def, a3, n3);
  def := replace(def, a4, n4);
  execute def;
end;
$do$;

-- team_exceptions(): per active consultant, only the things a manager should look at.
--   off_plan      last full week's actuals below half their plan (CVs, interview requests, interviews)
--   backlog       25+ calls on their queue today, or 3+ stages out of date
-- Thresholds tuned on 26/10/2026: at 70% and 10+ calls every consultant was flagged, which is not an
-- exceptions view. People in app_settings.exceptions_exclude_ids (Dale Barnett, the manager) are left out.
--   ratios        CV to interview or interview to offer over the last 8 weeks more than 30% below their
--                 previous 6 months, with at least 20 CVs (or 10 interviews) in the 8 weeks
--   visits        client visits done and booked below the pace for the quarter (2 by the end), from week 4
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
      -- off plan, last full week
      (select jsonb_agg(m) from (
         select format('%s %s of %s', label, coalesce((select n from last_week lw2 where lw2.consultant = p.name and lw2.stage_metric = metric), 0), target) m
         from plan pl, lateral (values ('CVs', 'cv_sent', (pl.x->'plan'->>'cv_sent')::numeric),
                                       ('interview requests', 'interview_request', (pl.x->'plan'->>'interview_request')::numeric),
                                       ('interviews', 'first_interview', (pl.x->'plan'->>'first_interview')::numeric)) v(label, metric, target)
         where pl.x->>'consultant' = p.name
           and coalesce((select n from last_week lw2 where lw2.consultant = p.name and lw2.stage_metric = metric), 0) < 0.5 * target) s) off_plan,
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
    'rules', 'Off plan: last full week below half the plan. Backlog: 25+ calls queued or 3+ stages out of date. Ratios: last 8 weeks more than 30% below the previous 6 months, with enough volume. Visits: below the pace for 2 per quarter, from week 4.',
    'exceptions', coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object('consultant', name, 'off_plan', off_plan, 'backlog', backlog,
                     'ratios', ratios, 'visits', visits)) order by name)
                   from ex_rows where off_plan is not null or backlog is not null or ratios is not null or visits is not null), '[]'::jsonb),
    'clear', coalesce((select jsonb_agg(name order by name) from ex_rows
                       where off_plan is null and backlog is null and ratios is null and visits is null), '[]'::jsonb));
$function$;
revoke execute on function public.team_exceptions() from public, anon, authenticated;
grant execute on function public.team_exceptions() to service_role;

-- Who gets the Monday exceptions DM. Starts with Oliver only; add managers' work emails, comma-separated.
insert into app_settings (key, value, updated_at) values
  ('manager_exceptions_emails', 'olarkins@octagongroup.co.uk', now()),
  ('exceptions_exclude_ids', '77604', now())   -- Dale Barnett, the manager
on conflict (key) do nothing;
