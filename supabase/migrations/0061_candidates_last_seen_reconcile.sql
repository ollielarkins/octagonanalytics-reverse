-- 0061_candidates_last_seen_reconcile.sql
-- The candidates reconcile had never once run to completion, so nothing had ever been written to
-- candidates.deleted_at and the mirror carried rows RecruitCRM no longer has.
--
-- The dedicated reconcile fetches every live id - 518 pages - then compares in one pass. That is
-- roughly two minutes of paging inside a background task that gets killed first. It fails safe (it
-- refuses to act on a partial fetch) but it can never finish, while still writing a fresh
-- last_run_at, so health showed green while it did nothing. Same silent-no-op shape as the bugs the
-- watchdog exists to catch.
--
-- Replaced by a reconcile that rides on paging we already do. Every live candidate is stamped with
-- last_seen_at on upsert, so after a COMPLETE backfill pass anything older than the pass start was
-- not returned by RecruitCRM and is gone upstream. One pass now does both jobs and cannot
-- half-finish into a wrong answer.

alter table public.candidates add column if not exists last_seen_at timestamptz;

comment on column public.candidates.last_seen_at is
  'Stamped every time RecruitCRM returns this candidate in a list sync. A row not stamped during a completed full backfill pass no longer exists upstream. Drives retire_unseen_candidates().';

create index if not exists candidates_last_seen_idx on public.candidates (last_seen_at) where deleted_at is null;

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
  select count(*) into total from public.candidates where deleted_at is null;
  select count(*) into n from public.candidates
   where deleted_at is null and (last_seen_at is null or last_seen_at < p_pass_start);

  -- Guard. A backfill that silently returned short would otherwise mass-retire live candidates -
  -- exactly the failure the paged reconcile's "partial fetch" check exists to prevent. Refuse
  -- rather than act on a suspicious pass; a real deletion rate is a fraction of a percent.
  if total > 0 and n > (total * 0.05) then
    raise exception 'retire_unseen_candidates: refusing to retire % of % live rows (>5%%) - pass likely incomplete', n, total;
  end if;

  update public.candidates set deleted_at = now()
   where deleted_at is null and (last_seen_at is null or last_seen_at < p_pass_start);
  get diagnostics n = row_count;
  return n;
end;
$function$;

revoke all on function public.retire_unseen_candidates(timestamptz) from public, anon, authenticated;
grant execute on function public.retire_unseen_candidates(timestamptz) to service_role;
