-- 0049_job_pipeline_by_id.sql
-- job_pipeline matched on title ILIKE or exact slug only, so passing a job ID — the number a
-- recruiter can see in RecruitCRM's own UI — searched for that digit string inside job titles and
-- reported the job did not exist. Job 6011 is real; it is the newest job in the table.
--
-- The "never show internal IDs/slugs" rule is about what we PRINT. Refusing an ID as INPUT just
-- discards the most precise handle the recruiter has. Numeric input now matches recruitcrm_id, and
-- the matched id is echoed back so they can confirm it is the job they meant.
create or replace function public.job_pipeline(p_job text, p_limit integer default 50)
returns jsonb language sql stable security definer set search_path to 'public' as $function$
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
  latest as (
    select distinct on (e.candidate_slug, e.job_slug)
      e.job_slug, e.candidate_slug, e.candidate_name, e.stage_name, e.event_date
    from candidate_stage_events e
    join jobs_m j on j.slug = e.job_slug
    order by e.candidate_slug, e.job_slug, e.event_timestamp desc
  )
  select jsonb_build_object(
    'query', p_job,
    'matched', (select count(*) from jobs_m),
    'jobs', (select coalesce(jsonb_agg(jsonb_build_object(
        'job_id', j.recruitcrm_id, 'job_title', j.title, 'job_slug', j.slug, 'status', j.status,
        'candidates_in_play', (select count(*) from latest l where l.job_slug = j.slug),
        'candidates', (select coalesce(jsonb_agg(jsonb_build_object(
             'name', l.candidate_name, 'candidate_slug', l.candidate_slug,
             'current_stage', l.stage_name, 'last_activity', l.event_date)
             order by l.event_date desc), '[]'::jsonb)
           from (select * from latest l2 where l2.job_slug = j.slug limit greatest(coalesce(p_limit,50),1)) l)
      ) order by (j.status='Open') desc), '[]'::jsonb) from jobs_m j)
  );
$function$;
