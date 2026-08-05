-- 0026_candidate_matching.sql
-- JD → candidate matching. Claude extracts the skills from a pasted job description and
-- calls match_candidates(skills[]); the function scores mirror candidates by how many of
-- those skills appear in their RecruitCRM `skill` text, and returns the matched skills +
-- the roles they've been submitted to, so Claude can rank and EXPLAIN the fit.
--
-- Requires candidates.skill (added here; populated by recruitcrm-sync's mapCandidate).
-- pg_trgm makes the per-skill ILIKE search fast across ~9.5k candidates.

create extension if not exists pg_trgm with schema extensions;
alter table public.candidates add column if not exists skill text;
create index if not exists candidates_skill_trgm on public.candidates using gin (skill extensions.gin_trgm_ops);

create or replace function public.match_candidates(p_skills text[], p_location text default null, p_limit int default 20)
returns jsonb language sql stable security definer set search_path to 'public' as $function$
  with q as (
    select distinct lower(trim(s)) skill from unnest(coalesce(p_skills, '{}')) s where length(trim(s)) > 1
  ),
  cand as (
    select c.slug, c.name, c.city, c.country, c.skill,
      (select count(*) from q where c.skill ilike '%'||q.skill||'%') score,
      (select array_agg(q.skill) from q where c.skill ilike '%'||q.skill||'%') matched
    from candidates c
    where c.skill is not null and c.skill <> ''
      and (p_location is null or c.city ilike '%'||p_location||'%' or c.country ilike '%'||p_location||'%')
  ),
  top as (
    select * from cand where score > 0 order by score desc, name limit greatest(coalesce(p_limit,20),1)
  )
  select jsonb_build_object(
    'skills_searched', (select coalesce(array_agg(skill), '{}') from q),
    'candidates_with_skills', (select count(*) from candidates where skill is not null and skill <> ''),
    'match_count', (select count(*) from cand where score > 0),
    'definition', 'Candidates whose RecruitCRM skill text contains the searched skills, ranked by number of matches. recent_roles = job titles they have been submitted to (context for explaining fit). Only candidates with skill text populated are considered.',
    'candidates', (select coalesce(jsonb_agg(jsonb_build_object(
       'name', name, 'candidate_slug', slug, 'city', city, 'country', country,
       'match_score', score, 'matched_skills', matched, 'skills', left(skill, 400),
       'recent_roles', (select coalesce(jsonb_agg(distinct e.job_title), '[]'::jsonb)
                        from candidate_stage_events e where e.candidate_slug = top.slug and e.job_title is not null)
       ) order by score desc, name), '[]'::jsonb) from top)
  );
$function$;

revoke all on function public.match_candidates(text[],text,int) from public, anon, authenticated;
grant execute on function public.match_candidates(text[],text,int) to service_role;
