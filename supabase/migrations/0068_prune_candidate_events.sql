-- 0068_prune_candidate_events.sql
-- candidate_stage_events was append-only: historyForCandidate upserted and nothing anywhere ever
-- deleted from it. /candidates/{slug}/history returns a candidate's COMPLETE current history, so
-- when RecruitCRM drops an entry - an assignment removed, a stage move undone, records merged - the
-- API is telling us it is gone and we kept it anyway.
--
-- Same defect as the candidate mirror before the last_seen_at retire in 0064. Fix is the same
-- shape: after walking a candidate, delete what the response did not contain.
--
-- Safe to delete rather than soft-delete: every row is re-derivable from the API, so a wrong prune
-- self-heals on the next walk. Comparison is on typed columns via jsonb_to_recordset, not on
-- stringified keys, so a timestamp format difference cannot silently match nothing and wipe a
-- candidate's history.
--
-- Worth recording honestly: this was built on the prediction that stale events explained the
-- remaining gap against RecruitCRM's report. It did not. Re-walking all 1,067 January candidates
-- pruned ZERO rows, which proved our mirror is a faithful copy of the API rather than a stale
-- superset - a useful negative result, and the reason the search then moved to attribution (0066)
-- and stage grain (0067), which is where the answer actually was.
--
-- The change stays because append-only was a genuine latent defect: without it the table could only
-- ever drift high, and nothing would have corrected it.
--
-- Applied 02/09/2026 as prune_candidate_events, between 0065 and 0066; file written retrospectively
-- after an audit found it missing from the repo. Paired with recruitcrm-sync v38, which calls it.

create or replace function public.prune_candidate_events(p_candidate_slug text, p_keep jsonb)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare n integer;
begin
  if p_candidate_slug is null or p_candidate_slug = '' then return 0; end if;

  delete from public.candidate_stage_events e
   where e.candidate_slug = p_candidate_slug
     and not exists (
       select 1
       from jsonb_to_recordset(coalesce(p_keep, '[]'::jsonb))
            as k(job_slug text, stage_metric text, event_timestamp timestamp)
       where k.job_slug = e.job_slug
         and k.stage_metric = e.stage_metric
         and k.event_timestamp = e.event_timestamp
     );

  get diagnostics n = row_count;
  return n;
end;
$function$;

revoke all on function public.prune_candidate_events(text, jsonb) from public, anon, authenticated;
grant execute on function public.prune_candidate_events(text, jsonb) to service_role;
