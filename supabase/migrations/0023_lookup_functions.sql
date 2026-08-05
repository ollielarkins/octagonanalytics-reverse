-- 0023_lookup_functions.sql
-- Lookup reads that (a) answer "what's happening with X" and (b) resolve a name to the
-- slug the write tools need. Served from the mirror (fast, consistent). These return
-- candidate NAMES (PII) — deliberately minimal (name + slug + stage; no email/phone),
-- callable only by service_role (the connector), always behind a per-user token.

-- find_candidate: search candidates by name -> slug + current stage on each job.
create or replace function public.find_candidate(p_name text, p_limit int default 10)
returns jsonb language sql stable security definer set search_path to 'public' as $function$
  with matches as (
    select recruitcrm_id, slug, name from candidates
    where p_name is not null and name ilike '%'||p_name||'%'
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

-- job_pipeline: resolve a job by title/slug -> who is in play and at what current stage.
create or replace function public.job_pipeline(p_job text, p_limit int default 50)
returns jsonb language sql stable security definer set search_path to 'public' as $function$
  with jobs_m as (
    select id, slug, title, status from jobs
    where deleted_at is null and p_job is not null
      and (title ilike '%'||p_job||'%' or slug = p_job)
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
    'jobs', (select coalesce(jsonb_agg(jsonb_build_object(
        'job_title', j.title, 'job_slug', j.slug, 'status', j.status,
        'candidates_in_play', (select count(*) from latest l where l.job_slug = j.slug),
        'candidates', (select coalesce(jsonb_agg(jsonb_build_object(
             'name', l.candidate_name, 'candidate_slug', l.candidate_slug,
             'current_stage', l.stage_name, 'last_activity', l.event_date)
             order by l.event_date desc), '[]'::jsonb)
           from (select * from latest l2 where l2.job_slug = j.slug limit greatest(coalesce(p_limit,50),1)) l)
      ) order by (j.status='Open') desc), '[]'::jsonb) from jobs_m j)
  );
$function$;

revoke all on function public.find_candidate(text,int) from public, anon, authenticated;
revoke all on function public.job_pipeline(text,int)   from public, anon, authenticated;
grant execute on function public.find_candidate(text,int) to service_role;
grant execute on function public.job_pipeline(text,int)   to service_role;
