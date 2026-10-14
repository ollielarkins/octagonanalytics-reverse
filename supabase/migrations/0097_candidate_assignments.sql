-- Candidate assignments: who put which candidate on which job, and when.
--
-- Reported 14/10/2026: Dale assigned 22 candidates through Claude and saw them nowhere in the
-- stats. RecruitCRM records each assignment in the candidate's hiring-stage history as the
-- "Assigned" stage (id 1), credited to whoever did it, but the history sync drops every stage not
-- in stage_lookup, so Assigned never reached the mirror. That is also why Dale's end-of-week
-- table had a "Candidates assigned" column we could not fill.
--
-- Kept OUT of candidate_stage_events on purpose. Every funnel, stalled, current-stage and
-- conversion report reads that table, and an assignment is not a funnel stage: adding ~15x more
-- rows of a new metric there would shift "latest stage" and "last activity" logic in ways each
-- report would have to be re-checked for. Here it touches nothing else.
--
-- Rebuilt per candidate on every history walk (replace_candidate_assignments), because the
-- endpoint returns the candidate's complete current history: an un-assignment simply disappears.
create table if not exists public.candidate_assignments (
  candidate_slug  text not null,
  job_slug        text not null,
  assigned_at     timestamp without time zone not null,
  assigned_date   date not null,
  candidate_id    bigint,
  candidate_name  text,
  job_id          bigint,
  job_title       text,
  consultant_id   bigint,
  consultant      text,
  created_at      timestamp without time zone not null default now(),
  primary key (candidate_slug, job_slug, assigned_at)
);
create index if not exists candidate_assignments_date_idx on public.candidate_assignments (assigned_date);
create index if not exists candidate_assignments_consultant_idx on public.candidate_assignments (consultant_id, assigned_date);
alter table public.candidate_assignments enable row level security;   -- service role only

-- Atomically replace one candidate's assignments with what their history says now.
create or replace function public.replace_candidate_assignments(p_candidate_slug text, p_rows jsonb)
returns integer language plpgsql security definer set search_path to 'public' as $function$
declare n integer;
begin
  delete from candidate_assignments where candidate_slug = p_candidate_slug;
  insert into candidate_assignments (candidate_slug, job_slug, assigned_at, assigned_date, candidate_id, candidate_name, job_id, job_title, consultant_id, consultant)
  select p_candidate_slug, r->>'job_slug', (r->>'assigned_at')::timestamp, (r->>'assigned_at')::date,
         nullif(r->>'candidate_id','')::bigint, r->>'candidate_name', nullif(r->>'job_id','')::bigint, r->>'job_title',
         nullif(r->>'consultant_id','')::bigint, r->>'consultant'
  from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) r
  where r->>'job_slug' is not null and r->>'assigned_at' is not null
  on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end;
$function$;
revoke all on function public.replace_candidate_assignments(text, jsonb) from public, anon, authenticated;
grant execute on function public.replace_candidate_assignments(text, jsonb) to service_role;

-- Backfill: re-walk every candidate changed since 01/09/2026 through the normal history queue
-- (history-recent, 50 a minute), which now captures their assignments. ~2,200 candidates.
update public.candidates set history_walked_at = null
where deleted_at is null and slug is not null and updated_date >= '2026-09-01';
