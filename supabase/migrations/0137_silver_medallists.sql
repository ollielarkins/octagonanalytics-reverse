-- 0137_silver_medallists.sql
-- Silver medallists: candidates who reached 2nd interview, 3rd interview or Offered on a job and were
-- then rejected (by the client or by us, which includes declined offers). They are already qualified,
-- already interview-tested, and the cheapest CV sends we have. Found in the command gap review
-- (03/11/2026): 182 in 2026 YTD against 143 open jobs, and no command surfaced them.
--
-- One row per candidate: their closest miss in the window (highest stage, then most recent). Left out,
-- and counted: candidates placed anywhere since that rejection, candidates already back in play on an
-- Open job, off-limit candidates (unless asked for), deleted records. Attributed to the owner of the
-- job they missed, like every desk view. Suggested roles are Open jobs whose title is closest to the
-- missed job's (trigram similarity), never one they are already on: a starting list for the
-- consultant to judge, not a match.

create or replace function public.silver_medallists(p_from date default null, p_to date default null, p_consultant text default null,
  p_limit int default 50, p_include_off_limit boolean default false)
returns jsonb
language sql
stable security definer
set search_path to 'public', 'extensions'
as $function$
  with w as (
    select coalesce(p_from, date '2026-01-01') f, coalesce(p_to, (now() at time zone 'Europe/London')::date + 1) t
  ),
  reach(metric, r, label) as (values ('second_interview', 1, '2nd Interview'), ('third_interview', 2, '3rd Interview'), ('offered', 3, 'Offered')),
  pair_latest as (
    select distinct on (e.candidate_slug, e.job_slug) e.candidate_slug, e.job_slug, e.stage_metric, e.event_date
    from candidate_stage_events e
    order by e.candidate_slug, e.job_slug, e.event_timestamp desc
  ),
  pair_best as (
    select e.candidate_slug, e.job_slug, max(r.r) best
    from candidate_stage_events e join reach r on r.metric = e.stage_metric
    group by 1, 2
  ),
  lost as (
    select l.candidate_slug, l.job_slug, b.best, l.stage_metric rejected_by, l.event_date rejected_on
    from pair_latest l join pair_best b using (candidate_slug, job_slug), w
    where l.stage_metric in ('rejected_client', 'rejected_consultant') and l.event_date >= w.f and l.event_date < w.t
  ),
  closest as (
    select distinct on (candidate_slug) * from lost order by candidate_slug, best desc, rejected_on desc
  ),
  flagged as (
    select b.*, c.name, c.city, c.skill, coalesce(c.off_limit, false) off_limit, c.deleted_at,
      j.title job_title, cl.company_name client, co.name consultant, (coalesce(co.active, true) and co.deleted_at is null) consultant_active,
      exists (select 1 from candidate_stage_events p where p.candidate_slug = b.candidate_slug and p.stage_metric = 'placed' and p.event_date >= b.rejected_on) placed_since,
      exists (select 1 from pair_latest a join jobs oj on oj.slug = a.job_slug and oj.deleted_at is null and oj.status = 'Open'
              where a.candidate_slug = b.candidate_slug
                and a.stage_metric in ('shortlist', 'cv_sent', 'interview_request', 'first_interview', 'second_interview', 'third_interview', 'offered')) in_play
    from closest b
    join candidates c on c.slug = b.candidate_slug
    left join jobs j on j.slug = b.job_slug
    left join clients cl on cl.id = j.client_id
    left join consultants co on co.id = j.consultant_id
  ),
  scoped as (
    select * from flagged where deleted_at is null and (p_consultant is null or consultant ilike '%' || p_consultant || '%')
  ),
  eligible as (
    select * from scoped where not placed_since and not in_play and (p_include_off_limit or not off_limit)
  ),
  top as (
    select * from eligible order by best desc, rejected_on desc limit greatest(coalesce(p_limit, 50), 1)
  ),
  open_jobs as (
    select j.slug, j.recruitcrm_id, j.title, cl.company_name client, co.name owner
    from jobs j left join clients cl on cl.id = j.client_id left join consultants co on co.id = j.consultant_id
    where j.deleted_at is null and j.status = 'Open'
  )
  select jsonb_build_object(
    'window', jsonb_build_object('from', (select f from w), 'to_exclusive', (select t from w)),
    'definition', 'Candidates who reached 2nd interview, 3rd interview or Offered on a job and were then rejected (client or consultant, which includes declined offers), one row per candidate at their closest miss. Excludes anyone placed since, anyone already back in play on an Open job, off-limit candidates unless asked for, and deleted records. Attributed to the owner of the job they missed. suggested_roles are Open jobs with the most similar title, for the consultant to judge.',
    'counts', jsonb_build_object(
      'rejected_after_late_stage', (select count(*) from scoped),
      'placed_since', (select count(*) from scoped where placed_since),
      'already_back_in_play', (select count(*) from scoped where in_play and not placed_since),
      'off_limit_excluded', (select count(*) from scoped where off_limit and not placed_since and not in_play and not p_include_off_limit),
      'available', (select count(*) from eligible),
      'shown', (select count(*) from top)),
    'by_consultant', coalesce((select jsonb_agg(jsonb_build_object('consultant', coalesce(consultant, 'No owner'), 'left', not consultant_active, 'available', n) order by n desc)
      from (select consultant, bool_and(consultant_active) consultant_active, count(*) n from eligible group by consultant) s), '[]'::jsonb),
    'candidates', coalesce((select jsonb_agg(jsonb_build_object(
        'candidate', t.name, 'candidate_slug', t.candidate_slug, 'city', t.city, 'skills', left(t.skill, 300),
        'off_limit', t.off_limit,
        'reached', (select label from reach where r = t.best), 'job_missed', t.job_title, 'client', t.client,
        'rejected_by', case t.rejected_by when 'rejected_client' then 'Client' else 'Consultant' end,
        'rejected_on', t.rejected_on, 'days_since', (now() at time zone 'Europe/London')::date - t.rejected_on,
        'consultant', t.consultant, 'consultant_left', not t.consultant_active,
        'suggested_roles', (select coalesce(jsonb_agg(jsonb_build_object('job_id', s.recruitcrm_id, 'title', s.title, 'client', s.client, 'owner', s.owner)), '[]'::jsonb)
          from (select o.* from open_jobs o
                where o.slug <> t.job_slug and t.job_title is not null
                  and similarity(lower(o.title), lower(t.job_title)) >= 0.3
                  and not exists (select 1 from candidate_stage_events x where x.candidate_slug = t.candidate_slug and x.job_slug = o.slug)
                order by similarity(lower(o.title), lower(t.job_title)) desc limit 3) s)
      ) order by t.best desc, t.rejected_on desc) from top t), '[]'::jsonb)
  );
$function$;
revoke execute on function public.silver_medallists(date, date, text, int, boolean) from public, anon, authenticated;
