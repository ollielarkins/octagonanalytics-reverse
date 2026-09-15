-- 0075_hide_deleted_from_operational.sql
-- Soft-delete existed but hid nothing. delete_record has tombstoned candidates/jobs/companies since
-- it was written, and reconcile_entity sets deleted_at on records that vanish from RecruitCRM — but
-- the read side never checked the column, so a deleted candidate still came back in search and could
-- still be matched to a job and pitched. Flagged as a follow-up on 03/08/2026, never done.
--
-- DECISION (Ollie, 15/09/2026): hide deleted records from OPERATIONAL surfaces only. Historical
-- counts keep them. Deleting a candidate today must not silently drop their CV sends out of last
-- quarter's numbers — the work happened, and retroactively moving history would also move parity
-- against RecruitCRM's own report. Same principle already applied to leavers: credited to whoever
-- did the work, never reattributed.
--
-- So this migration deliberately does NOT touch consultant_funnel, consultant_activity_daily/monthly,
-- consultant_rankings, pipeline_monthly, revenue_monthly, stage_timing, team_summary_monthly or
-- v_candidate_events. Those are history and must stay stable.
--
-- Operational surfaces already filtering correctly (verified, left alone): cold_jobs, stalled_report,
-- my_day, job_pipeline, client_report, dashboard_json, new_jobs_report, awaiting_feedback_report,
-- interview_requests_unbooked.

-- 1. deals had no deleted_at at all, which is why delete_record HARD-deletes a deal — it destroys the
--    row because there is nowhere to mark it. Give deals a tombstone like every other mirrored entity.
alter table public.deals add column if not exists deleted_at timestamptz;

-- 2. Live deal pipeline is a forward indicator, not history: a deleted deal must drop out of it.
create or replace view public.deal_pipeline_by_stage as
  select deal_stage,
         count(*) as total_deals,
         sum(deal_value) as total_value
    from deals
   where deal_stage is distinct from 'Won'
     and deal_stage is distinct from 'Lost'
     and deleted_at is null
   group by deal_stage
   order by (sum(deal_value)) desc nulls last;

-- 3. Candidate search must not return people who no longer exist.
create or replace function public.find_candidate(p_name text, p_limit integer default 10)
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  with matches as (
    select recruitcrm_id, slug, name from candidates
    where p_name is not null and name ilike '%'||p_name||'%'
      and deleted_at is null
    order by name limit greatest(coalesce(p_limit,10), 1)
  ),
  latest as (
    select distinct on (e.candidate_slug, e.job_slug)
      e.candidate_slug, e.job_slug, e.job_title, e.stage_name, e.event_date
    from candidate_stage_events e
    join matches m on m.slug = e.candidate_slug
    order by e.candidate_slug, e.job_slug, e.event_timestamp desc
  )
  select jsonb_build_object(
    'query', p_name,
    'match_count', (select count(*) from matches),
    'candidates', (select coalesce(jsonb_agg(jsonb_build_object(
        'name', m.name, 'candidate_slug', m.slug,
        'jobs', (select coalesce(jsonb_agg(jsonb_build_object(
             'job_title', l.job_title, 'job_slug', l.job_slug,
             'current_stage', l.stage_name, 'last_activity', l.event_date)
             order by l.event_date desc), '[]'::jsonb)
           from latest l where l.candidate_slug = m.slug)
      ) order by m.name), '[]'::jsonb) from matches m)
  );
$function$;

-- 4. Matching feeds pitching. Putting a deleted candidate in front of a client is the worst version
--    of this bug, so both overloads are fixed, not just the current one.
create or replace function public.match_candidates(p_skills text[], p_location text default null::text, p_limit integer default 20)
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  with q as (
    select distinct lower(trim(s)) skill from unnest(coalesce(p_skills, '{}')) s where length(trim(s)) > 1
  ),
  cand as (
    select c.slug, c.name, c.city, c.country, c.skill,
      (select count(*) from q where c.skill ilike '%'||q.skill||'%') score,
      (select array_agg(q.skill) from q where c.skill ilike '%'||q.skill||'%') matched
    from candidates c
    where c.skill is not null and c.skill <> ''
      and c.deleted_at is null
      and (p_location is null or c.city ilike '%'||p_location||'%' or c.country ilike '%'||p_location||'%')
  ),
  top as (
    select * from cand where score > 0 order by score desc, name limit greatest(coalesce(p_limit,20),1)
  )
  select jsonb_build_object(
    'skills_searched', (select coalesce(array_agg(skill), '{}') from q),
    'candidates_with_skills', (select count(*) from candidates where skill is not null and skill <> '' and deleted_at is null),
    'match_count', (select count(*) from cand where score > 0),
    'definition', 'Candidates whose RecruitCRM skill text contains the searched skills, ranked by number of matches. recent_roles = job titles they have been submitted to (context for explaining fit). Only candidates with skill text populated are considered. Deleted candidates are excluded.',
    'candidates', (select coalesce(jsonb_agg(jsonb_build_object(
       'name', name, 'candidate_slug', slug, 'city', city, 'country', country,
       'match_score', score, 'matched_skills', matched, 'skills', left(skill, 400),
       'recent_roles', (select coalesce(jsonb_agg(distinct e.job_title), '[]'::jsonb)
                        from candidate_stage_events e where e.candidate_slug = top.slug and e.job_title is not null)
       ) order by score desc, name), '[]'::jsonb) from top)
  );
$function$;

create or replace function public.match_candidates(p_skills text[], p_location text default null::text, p_limit integer default 20, p_include_off_limit boolean default false)
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  with q as (
    select distinct lower(trim(s)) skill from unnest(coalesce(p_skills, '{}')) s where length(trim(s)) > 1
  ),
  cand as (
    select c.slug, c.name, c.city, c.country, c.skill, c.off_limit, c.off_limit_reason,
      (select count(*) from q where c.skill ilike '%'||q.skill||'%') score,
      (select array_agg(q.skill) from q where c.skill ilike '%'||q.skill||'%') matched
    from candidates c
    where c.skill is not null and c.skill <> ''
      and c.deleted_at is null
      and (p_location is null or c.city ilike '%'||p_location||'%' or c.country ilike '%'||p_location||'%')
  ),
  matched_all as (select * from cand where score > 0),
  eligible as (select * from matched_all where p_include_off_limit or not off_limit),
  top as (
    select * from eligible order by score desc, name limit greatest(coalesce(p_limit,20),1)
  )
  select jsonb_build_object(
    'skills_searched', (select coalesce(array_agg(skill), '{}') from q),
    'candidates_with_skills', (select count(*) from candidates where skill is not null and skill <> '' and deleted_at is null),
    'match_count', (select count(*) from eligible),
    'off_limit_excluded', (select count(*) from matched_all where off_limit and not p_include_off_limit),
    'definition', 'Candidates whose RecruitCRM skill text contains the searched skills, ranked by number of matches. recent_roles = job titles they have been submitted to. Only candidates with skill text populated are considered. Candidates marked OFF LIMIT in RecruitCRM are excluded unless p_include_off_limit is true; off_limit_excluded says how many were dropped. Deleted candidates are always excluded.',
    'candidates', (select coalesce(jsonb_agg(jsonb_build_object(
       'name', name, 'candidate_slug', slug, 'city', city, 'country', country,
       'match_score', score, 'matched_skills', matched, 'skills', left(skill, 400),
       'off_limit', off_limit, 'off_limit_reason', case when off_limit then off_limit_reason end,
       'recent_roles', (select coalesce(jsonb_agg(distinct e.job_title), '[]'::jsonb)
                        from candidate_stage_events e where e.candidate_slug = top.slug and e.job_title is not null)
       ) order by score desc, name), '[]'::jsonb) from top)
  );
$function$;
