-- 0020_fix_cold_jobs_count.sql
-- Bugfix: cold_jobs.cold_count was counting the LIMIT-ed display set, so a call with
-- limit=3 reported cold_count=3 even when far more roles were cold (caught by the
-- admin digest, which computed the true 53). Split into cold_all (unbounded → the
-- count) and a separately-limited list for display.
create or replace function public.cold_jobs(
  p_days int default 14, p_consultant text default null, p_limit int default 50)
returns jsonb language sql stable security definer set search_path to 'public' as $function$
  with open_jobs as (
    select j.slug, j.title, j.created_date::date created, co.name consultant, cl.company_name client
    from jobs j
    join consultants co on j.consultant_id = co.id and co.deleted_at is null
    left join clients cl on j.client_id = cl.id and cl.deleted_at is null
    where j.deleted_at is null and j.status='Open'
      and (p_consultant is null or co.name ilike '%'||p_consultant||'%')
  ),
  last_act as (
    select job_slug, max(event_date) last_date from candidate_stage_events group by job_slug
  ),
  cold_all as (
    select o.title, o.client, o.consultant, o.created, l.last_date,
           (current_date - l.last_date) days_since
    from open_jobs o left join last_act l on l.job_slug = o.slug
    where l.last_date is null or l.last_date < current_date - make_interval(days => p_days)
  )
  select jsonb_build_object(
    'threshold_days', p_days,
    'definition','OPEN jobs whose most recent candidate_stage_event is older than threshold_days (or that have none). Job titles/clients only — no candidate PII. cold_count is the true total; jobs[] is capped at limit.',
    'cold_count', (select count(*) from cold_all),
    'jobs', (select coalesce(jsonb_agg(jsonb_build_object(
       'job_title',title,'client',client,'consultant',consultant,'opened',created,
       'last_activity', last_date, 'days_since_activity', days_since)
       order by coalesce(last_date, date '1900-01-01') asc), '[]'::jsonb)
       from (select * from cold_all order by coalesce(last_date, date '1900-01-01') asc limit p_limit) x)
  );
$function$;
