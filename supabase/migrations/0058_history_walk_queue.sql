-- 0058_history_walk_queue.sql
-- The funnel could only ever under-count, and did.
--
-- candidate_stage_events is the single source for every CV-send, interview and offer figure the
-- platform publishes, and it has exactly one writer: the history_recent cron. That job selected the
-- N most-recently-updated candidates inside a one-day window, offset pinned at 0. Two independent
-- ways that lost events:
--
--   1. The cap sat below daily churn. 27/08/2026 touched 170 candidates against max_candidates=50.
--      Everything past the cap was never walked, and the one-day window never looked back, so those
--      stage changes were lost for good rather than picked up late.
--   2. It read updated_date from OUR OWN mirror, so it silently inherited the candidates poller's
--      health. While that poller was down (21/08-01/09/2026) a candidate whose mirror row never
--      refreshed never entered the window at all, whatever they did in RecruitCRM.
--
-- Both are one-directional: they drop events, never invent them. That is why the published numbers
-- ran consistently low. 28/08/2026 recorded 4 CV sends against 7 in RecruitCRM's own stage-date
-- report, with candidates 51878 and 51882 holding zero stage events despite both being updated
-- inside the window that morning.
--
-- Replaces the time window with a watermark work queue: a candidate is due when it has never been
-- walked, or when its record changed after our last walk. Nothing falls off the tail, and a poller
-- outage now delays a walk instead of erasing it.
--
-- history_walked_at is deliberately left NULL on every existing row, which makes the whole base due
-- and drives a full re-walk of all ~17,345 candidates. cse_natural_key (candidate_slug, job_slug,
-- stage_metric, event_timestamp) makes that strictly additive - it can fill gaps but cannot
-- duplicate. At 60 per pass every 5 minutes it drains in roughly a day.

alter table public.candidates add column if not exists history_walked_at timestamp;

comment on column public.candidates.history_walked_at is
  'When the stage-history feed last walked this candidate. Null or older than updated_date means due. Drives candidates_due_for_history().';

create index if not exists candidates_history_due_idx
  on public.candidates (updated_date desc)
  where slug is not null;

-- PostgREST cannot express a column-to-column comparison in a filter, so the queue is an RPC rather
-- than a .or() on the client.
create or replace function public.candidates_due_for_history(p_limit int default 60)
returns table(recruitcrm_id bigint, slug text, name text, updated_date timestamp)
language sql
stable
security definer
set search_path to 'public'
as $function$
  select c.recruitcrm_id, c.slug, c.name, c.updated_date
  from public.candidates c
  where c.slug is not null
    and (c.history_walked_at is null or c.history_walked_at < c.updated_date)
  order by c.updated_date desc nulls last
  limit greatest(1, least(p_limit, 200));
$function$;

revoke all on function public.candidates_due_for_history(int) from public, anon, authenticated;
grant execute on function public.candidates_due_for_history(int) to service_role;

-- job_id had never been populated: all 19,786 rows were null, so job identity survived only through
-- job_slug and every report joined back through it. Backfill from the slug; the sync writes it
-- going forward (v33).
update public.candidate_stage_events e
set job_id = j.recruitcrm_id
from public.jobs j
where j.slug = e.job_slug and e.job_id is null;
