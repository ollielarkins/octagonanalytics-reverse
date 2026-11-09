-- 0157_sync_timeout_and_candidate_lock_order.sql
-- 09/11/2026. Two faults on the candidates table.
--
-- 1. Statement timeout. At 03:45:08 UTC on 09/11/2026 a 100-row candidates upsert from
--    recruitcrm-sync returned 500 "canceling statement due to statement timeout" (57014).
--    service_role has no statement_timeout of its own, so PostgREST requests made with the service
--    key fall back to authenticator's 8s. That is right for the dashboards (anon 3s,
--    authenticated 8s), but too short for sync batches that update a GIN trigram index (skill) and
--    can wait behind another writer's row locks. Give service_role 60s: still a ceiling, never
--    unbounded. The anon and authenticated limits are unchanged.
--
-- 2. Deadlocks. pg_stat_database shows 42 since 03/08/2026. apply_off_limit (every 20 minutes)
--    rewrote all ~93 off-limit rows in one transaction, in whatever order the join produced, while
--    the candidate backfill, incremental sync and webhook upsert overlapping rows in their own
--    order. Now:
--      - it locks the rows it will touch in recruitcrm_id order first (the sync's upserts are
--        sorted the same way from this change, see dedupeBy in recruitcrm-sync);
--      - it only writes rows whose flag, date or reason actually changed, so a steady list holds
--        no locks at all, instead of 93 every run.

alter role service_role set statement_timeout = '60s';
notify pgrst, 'reload config';

create or replace function public.apply_off_limit(p_rows jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_set int; v_cleared int;
begin
  create temp table _ol_src on commit drop as
    select distinct on (r->>'slug') r->>'slug' as slug, nullif(r->>'until','')::date as until, r->>'reason' as reason
      from jsonb_array_elements(p_rows) r
     where coalesce(r->>'slug','') <> '';

  -- Lock every row this call will change, in one fixed order, before changing any.
  perform 1 from candidates c
   where (exists (select 1 from _ol_src s where s.slug = c.slug
                   and (not c.off_limit or c.off_limit_until is distinct from s.until or c.off_limit_reason is distinct from s.reason)))
      or (c.off_limit and not exists (select 1 from _ol_src s where s.slug = c.slug))
   order by c.recruitcrm_id
   for update;

  update candidates c
     set off_limit = true, off_limit_until = s.until, off_limit_reason = s.reason
    from _ol_src s
   where c.slug = s.slug
     and (not c.off_limit or c.off_limit_until is distinct from s.until or c.off_limit_reason is distinct from s.reason);

  -- "set" keeps its old meaning: off-limit candidates found in the mirror (sync_health shows matched=).
  select count(*) into v_set from candidates c join _ol_src s on s.slug = c.slug;

  update candidates c
     set off_limit = false, off_limit_until = null, off_limit_reason = null
   where c.off_limit
     and not exists (select 1 from _ol_src s where s.slug = c.slug);
  get diagnostics v_cleared = row_count;

  return jsonb_build_object('set', v_set, 'cleared', v_cleared);
end $function$;
