-- 0162_lookups_include_assigned.sql
--
-- Reported 25/11/2026: Steve and Ollie applied as a test candidate through octagongroup.co.uk for the
-- Calnex BDM role. RecruitCRM created the candidate and put him on the job (Assigned) at 16:22. At
-- 16:25:46 Claude's find_candidate said he existed but was on no job, and job_pipeline did not list
-- him either, although his assignment had reached candidate_assignments at 16:25:07.
--
-- Both lookups built their job lists from candidate_stage_events only. Assigned is deliberately kept
-- out of that table (0097), so a candidate who is on a job but not yet moved to a stage (every
-- website applicant, every fresh assignment) was invisible to them: 5,330 candidate-job pairs across
-- 2,501 candidates on 25/11/2026.
--
-- Both now add those pairs from candidate_assignments, with current_stage 'Assigned' and
-- assigned_only true. Stage events still win where they exist, and nothing else reads these
-- functions' output, so no report changes. candidate_assignments may keep a row after a candidate is
-- taken off a job, so the output says to confirm an assigned_only row with candidate_profile (live)
-- before acting on it.

create or replace function public.find_candidate(p_name text, p_limit integer default 10)
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  with matches as (
    select recruitcrm_id, slug, name from candidates
    where p_name is not null
      and deleted_at is null
      and (name ilike '%'||p_name||'%'
           or recruitcrm_id = case when btrim(p_name) ~ '^[0-9]{1,18}$' then btrim(p_name)::bigint end)
    order by name limit greatest(coalesce(p_limit,10), 1)
  ),
  staged as (
    select distinct on (e.candidate_slug, e.job_slug)
      e.candidate_slug, e.job_slug, e.job_title, e.stage_name, e.event_date, false as assigned_only
    from candidate_stage_events e
    join matches m on m.slug = e.candidate_slug
    order by e.candidate_slug, e.job_slug, e.event_timestamp desc
  ),
  assigned as (
    select distinct on (a.candidate_slug, a.job_slug)
      a.candidate_slug, a.job_slug, coalesce(j.title, a.job_title) as job_title, 'Assigned'::text as stage_name,
      a.assigned_date as event_date, true as assigned_only
    from candidate_assignments a
    join matches m on m.slug = a.candidate_slug
    left join jobs j on j.slug = a.job_slug
    where not exists (select 1 from staged s where s.candidate_slug = a.candidate_slug and s.job_slug = a.job_slug)
    order by a.candidate_slug, a.job_slug, a.assigned_at desc
  ),
  latest as (select * from staged union all select * from assigned)
  select jsonb_build_object(
    'query', p_name,
    'match_count', (select count(*) from matches),
    'candidates', (select coalesce(jsonb_agg(jsonb_build_object(
        'name', m.name, 'candidate_slug', m.slug,
        'jobs', (select coalesce(jsonb_agg(jsonb_build_object(
             'job_title', l.job_title, 'job_slug', l.job_slug,
             'current_stage', l.stage_name, 'last_activity', l.event_date,
             'assigned_only', case when l.assigned_only then true end)
             order by l.event_date desc), '[]'::jsonb)
           from latest l where l.candidate_slug = m.slug)
      ) order by m.name), '[]'::jsonb) from matches m),
    'note', 'jobs lists every job the candidate is on: stage moves, plus assignments with no stage move yet (current_stage Assigned, assigned_only true: website applicants and fresh assignments). An assignment can stay listed after the candidate was taken off the job, so confirm an assigned_only job with candidate_profile (live from RecruitCRM) before saying they are or are not on it. A candidate added in the last few minutes may not have their job here yet: check candidate_profile before saying they are on no job.'
  );
$function$;

create or replace function public.job_pipeline(p_job text, p_limit integer default 50)
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  with jobs_m as (
    select id, recruitcrm_id, slug, title, status from jobs
    where deleted_at is null and p_job is not null
      and (
        (p_job ~ '^[0-9]+$' and recruitcrm_id = p_job::bigint)   -- a job ID
        or slug = p_job                                          -- an exact slug
        or title ilike '%'||p_job||'%'                           -- part of a title
      )
    order by (status='Open') desc, created_date desc
    limit 5
  ),
  staged as (
    select distinct on (e.candidate_slug, e.job_slug)
      e.job_slug, e.candidate_slug, e.candidate_name, e.stage_name, e.event_date, false as assigned_only
    from candidate_stage_events e
    join jobs_m j on j.slug = e.job_slug
    order by e.candidate_slug, e.job_slug, e.event_timestamp desc
  ),
  assigned as (
    select distinct on (a.candidate_slug, a.job_slug)
      a.job_slug, a.candidate_slug, coalesce(c.name, a.candidate_name) as candidate_name, 'Assigned'::text as stage_name,
      a.assigned_date as event_date, true as assigned_only
    from candidate_assignments a
    join jobs_m j on j.slug = a.job_slug
    left join candidates c on c.slug = a.candidate_slug
    where not exists (select 1 from staged s where s.candidate_slug = a.candidate_slug and s.job_slug = a.job_slug)
      and (c.slug is null or c.deleted_at is null)
    order by a.candidate_slug, a.job_slug, a.assigned_at desc
  ),
  latest as (select * from staged union all select * from assigned)
  select jsonb_build_object(
    'query', p_job,
    'matched', (select count(*) from jobs_m),
    'jobs', (select coalesce(jsonb_agg(jsonb_build_object(
        'job_id', j.recruitcrm_id, 'job_title', j.title, 'job_slug', j.slug, 'status', j.status,
        'candidates_in_play', (select count(*) from staged l where l.job_slug = j.slug),
        'assigned_no_stage_yet', (select count(*) from assigned l where l.job_slug = j.slug),
        'candidates', (select coalesce(jsonb_agg(jsonb_build_object(
             'name', l.candidate_name, 'candidate_slug', l.candidate_slug,
             'current_stage', l.stage_name, 'last_activity', l.event_date,
             'assigned_only', case when l.assigned_only then true end)
             order by l.event_date desc), '[]'::jsonb)
           from (select * from latest l2 where l2.job_slug = j.slug
                 order by l2.assigned_only, l2.event_date desc
                 limit greatest(coalesce(p_limit,50),1)) l)
      ) order by (j.status='Open') desc), '[]'::jsonb) from jobs_m j),
    'note', 'candidates includes people assigned to the job with no stage move yet (current_stage Assigned, assigned_only true), such as website applicants; candidates_in_play counts only those moved to a stage, as before. An assignment can stay listed after the candidate was taken off the job: confirm with candidate_profile before acting on an assigned_only row.'
  );
$function$;

revoke all on function public.find_candidate(text, integer) from public, anon, authenticated;
grant execute on function public.find_candidate(text, integer) to service_role;
revoke all on function public.job_pipeline(text, integer) from public, anon, authenticated;
grant execute on function public.job_pipeline(text, integer) to service_role;
