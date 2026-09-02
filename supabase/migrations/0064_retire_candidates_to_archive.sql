-- 0064_retire_candidates_to_archive.sql
-- Soft-delete only works if every reader filters on it, and for candidates none of them did.
--
-- octagon-mcp has fourteen deleted_at filters; every one was on clients or jobs. All three candidate
-- reads - resolveCandidate (used before pitching, assigning or moving a stage), refreshCandidate,
-- and the create_candidate duplicate check - queried the table unfiltered. So a retired candidate
-- kept appearing in search indefinitely, could block a real new record as a false duplicate, and
-- would 404 at the RecruitCRM API if anyone acted on them.
--
-- Latent until 02/09/2026: nothing had ever been written to candidates.deleted_at, because the
-- candidates reconcile had never once completed. Fixing the reconcile (0061/0062) made it live, and
-- find_candidate immediately returned two Crepin Mbappe records - one live, one retired.
--
-- The reader-side fix is three .is("deleted_at", null) calls and those are committed against
-- octagon-mcp. But deploying that function means retransmitting ~180KB of the code behind every
-- tool and the dashboard, with no rollback. So close it on the write side instead, where it cannot
-- be got wrong: retired candidates leave the table entirely and land in candidates_archive. Every
-- reader is then correct by construction, including any future one that forgets to filter.
--
-- Nothing is lost and it stays reversible - the full row is preserved, so a mistaken retire can be
-- reinstated with an insert back.
--
-- Applied 02/09/2026 as retire_candidates_to_archive; file written retrospectively after an audit
-- found it missing from the repo.

create table if not exists public.candidates_archive (
  like public.candidates including defaults,
  archived_at timestamptz not null default now(),
  archived_reason text
);
create index if not exists candidates_archive_rid_idx on public.candidates_archive (recruitcrm_id);
create index if not exists candidates_archive_slug_idx on public.candidates_archive (slug);

comment on table public.candidates_archive is
  'Candidates RecruitCRM no longer returns. Moved out of candidates by retire_unseen_candidates() so no reader can surface them by forgetting a filter. Full row preserved; reinstate with an insert back.';

alter table public.candidates_archive enable row level security;
drop policy if exists service_role_only on public.candidates_archive;
create policy service_role_only on public.candidates_archive
  as restrictive for all to anon, authenticated using (false) with check (false);

create or replace function public.retire_unseen_candidates(p_pass_start timestamptz)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  n integer;
  total integer;
begin
  select count(*) into total from public.candidates;
  select count(*) into n from public.candidates
   where last_seen_at is null or last_seen_at < p_pass_start;

  -- Guard. A backfill that silently returned short would otherwise retire live candidates wholesale -
  -- the failure the paged reconcile's "partial fetch" check exists to prevent. Refuse rather than act
  -- on a suspicious pass; a real deletion rate is a fraction of a percent.
  if total > 0 and n > (total * 0.05) then
    raise exception 'retire_unseen_candidates: refusing to retire % of % rows (>5%%) - pass likely incomplete', n, total;
  end if;

  with gone as (
    delete from public.candidates
     where last_seen_at is null or last_seen_at < p_pass_start
    returning *
  )
  insert into public.candidates_archive
  select g.*, now(), 'not returned by backfill pass starting ' || p_pass_start
  from gone g;

  get diagnostics n = row_count;
  return n;
end;
$function$;

revoke all on function public.retire_unseen_candidates(timestamptz) from public, anon, authenticated;
grant execute on function public.retire_unseen_candidates(timestamptz) to service_role;

-- Move the two rows already soft-deleted in place by the first working pass.
with gone as (
  delete from public.candidates where deleted_at is not null returning *
)
insert into public.candidates_archive
select g.*, now(), 'migrated from in-place soft delete (0064)' from gone g;
