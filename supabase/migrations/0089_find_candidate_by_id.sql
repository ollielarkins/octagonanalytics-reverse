-- 0089_find_candidate_by_id.sql
-- /find matched on name only, so a recruiter pasting a RecruitCRM candidate ID got nothing back.
-- An all-digit query now also matches recruitcrm_id exactly. Body otherwise as 0075 (deleted
-- candidates stay hidden).

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
           -- CASE, not AND: Postgres does not promise to short-circuit, and casting a 19+ digit
           -- string to bigint raises instead of returning no match.
           or recruitcrm_id = case when btrim(p_name) ~ '^[0-9]{1,18}$' then btrim(p_name)::bigint end)
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

revoke all on function public.find_candidate(text,integer) from public, anon, authenticated;
grant execute on function public.find_candidate(text,integer) to service_role;
