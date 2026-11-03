-- 0140_aftercare.sql
-- Aftercare: the check-ins due on placements, so a hire that is wobbling gets a call before it falls
-- through. Found in the command gap review (03/11/2026): nothing tracked placements after Won.
--
-- Placements come from Won deals with a start date (126 of 127 in 2026): the Placed stage records its
-- start date only in a stage remark, which is not mirrored. The candidate is whoever was moved to
-- Placed on the deal's job, the one nearest the deal's close date when there are several; a deal with
-- no Placed candidate is shown by its deal name. Attributed to the deal owner, like billing.
--
-- Four check-ins per placement: before start (the 7 days up to the start date), week 1 (start + 7),
-- month 1 (start + 30) and month 3 (start + 91). A check-in is listed from 7 days before it is due
-- (p_ahead_days) until 14 days after (then it is history). contacted_since marks a call or note
-- logged against the candidate since the check-in window opened, so the recruiter can skip one that
-- has plainly happened; nothing is marked done automatically. No rebate dates: Octagon's rebate
-- terms are not recorded anywhere (Oliver, 03/11/2026: leave them out until confirmed).

create or replace function public.aftercare(p_consultant text default null, p_ahead_days int default 7)
returns jsonb
language sql
stable security definer
set search_path to 'public'
as $function$
  with today as (select (now() at time zone 'Europe/London')::date t),
  placements as (
    select d.slug deal_slug, d.deal_name, d.start_date::date start_date, d.close_date, d.job_slug, d.company_slug,
      co.name consultant, (co.id is not null and coalesce(co.active, true) and co.deleted_at is null) consultant_active,
      cl.company_name client, j.title job_title,
      (select e.candidate_slug from candidate_stage_events e where e.job_slug = d.job_slug and e.stage_metric = 'placed'
        order by abs(e.event_date - coalesce(d.close_date::date, d.start_date::date)), e.event_timestamp desc limit 1) candidate_slug
    from deals d
    left join consultants co on co.recruitcrm_id = d.owner_recruitcrm_id
    left join clients cl on cl.company_slug = d.company_slug
    left join jobs j on j.slug = d.job_slug
    , today
    where d.deleted_at is null and d.deal_stage = 'Won' and d.start_date is not null
      and d.start_date::date between today.t - 105 and today.t + 14
  ),
  checks(kind, label, offset_days, opens_before) as (
    values ('before_start', 'Before start', 0, 7), ('week_1', 'Week 1', 7, 2), ('month_1', 'Month 1', 30, 3), ('month_3', 'Month 3', 91, 7)
  ),
  due as (
    select p.*, c.kind, c.label, (p.start_date + c.offset_days) due_on, (p.start_date + c.offset_days - c.opens_before) opens_on
    from placements p cross join checks c, today
    where p.start_date + c.offset_days between today.t - 14 and today.t + greatest(coalesce(p_ahead_days, 7), 0)
      and (c.kind <> 'before_start' or p.start_date >= today.t)
  ),
  scored as (
    select d.*, cand.name candidate,
      (select max(x) from (
         select max(a.call_started_on)::date x from call_activity a where a.related_to_type = 'candidate' and a.related_to = d.candidate_slug
         union all
         select max(n.created_on)::date from notes n where n.related_to_type = 'candidate' and n.related_to = d.candidate_slug) m) last_contact
    from due d left join candidates cand on cand.slug = d.candidate_slug
    where p_consultant is null or d.consultant ilike '%' || p_consultant || '%'
  )
  select jsonb_build_object(
    'today', (select t from today),
    'definition', 'Check-ins on placements from Won deals with a start date: before start (the week up to it), week 1 (+7 days), month 1 (+30), month 3 (+91). Listed from up to ahead_days before due until 14 days after. contacted_since = a call or note logged against the candidate since the check-in window opened; nothing is marked done automatically. Attributed to the deal owner. No rebate dates: the rebate terms are not recorded.',
    'ahead_days', greatest(coalesce(p_ahead_days, 7), 0),
    'counts', jsonb_build_object(
      'due', (select count(*) from scored),
      'overdue_no_contact', (select count(*) from scored, today where due_on < today.t and not coalesce(last_contact >= opens_on, false)),
      'no_candidate_found', (select count(*) from scored where candidate_slug is null)),
    'checkins', coalesce((select jsonb_agg(jsonb_build_object(
        'check_in', s.label, 'due_on', s.due_on, 'days_until_due', s.due_on - today.t,
        'candidate', coalesce(s.candidate, s.deal_name), 'candidate_slug', s.candidate_slug, 'job', s.job_title, 'client', s.client,
        'start_date', s.start_date, 'consultant', s.consultant, 'consultant_left', not s.consultant_active,
        'last_contact', s.last_contact, 'contacted_since', coalesce(s.last_contact >= s.opens_on, false)
      ) order by coalesce(s.last_contact >= s.opens_on, false), s.due_on) from scored s, today), '[]'::jsonb)
  );
$function$;
revoke execute on function public.aftercare(text, int) from public, anon, authenticated;
