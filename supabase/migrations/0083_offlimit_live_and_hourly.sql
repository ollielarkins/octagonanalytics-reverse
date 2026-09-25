-- 0083_offlimit_live_and_hourly.sql
-- Off-limit: atomic apply, hourly refresh, monitor thresholds to match.
-- Run BEFORE deploying the new recruitcrm-sync (it calls apply_off_limit).

-- 1. Apply the full off-limit list in one transaction. Readers see the old set or the new set,
--    never the empty moment the old clear-then-set loop created.
create or replace function public.apply_off_limit(p_rows jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_set int; v_cleared int;
begin
  with src as (
    select r->>'slug' as slug, nullif(r->>'until','')::date as until, r->>'reason' as reason
      from jsonb_array_elements(p_rows) r
     where coalesce(r->>'slug','') <> ''
  ), upd as (
    update candidates c
       set off_limit = true, off_limit_until = s.until, off_limit_reason = s.reason
      from src s where c.slug = s.slug
    returning c.slug
  )
  select count(*) into v_set from upd;

  update candidates
     set off_limit = false, off_limit_until = null, off_limit_reason = null
   where off_limit
     and slug not in (select r->>'slug' from jsonb_array_elements(p_rows) r where r->>'slug' is not null);
  get diagnostics v_cleared = row_count;

  return jsonb_build_object('set', v_set, 'cleared', v_cleared);
end $$;
-- SECURITY DEFINER + PostgREST = callable by anyone with the anon key unless revoked.
revoke execute on function public.apply_off_limit(jsonb) from public, anon, authenticated;

-- 2. Refresh hourly instead of daily. Keep the manifest in step or the cron watchdog alerts on drift.
select cron.alter_job(job_id := (select jobid from cron.job where jobname = 'offlimit-refresh'),
                      schedule := '25 * * * *');
update cron_manifest set schedule = '25 * * * *',
       note = coalesce(note, '') || ' Hourly from 25/09/2026 - /match reads this flag.'
 where jobname = 'offlimit-refresh';

-- 3. Monitor: was 26h warn / 50h critical for a daily job. Now 2h / 4h.
do $$
declare def text;
begin
  def := pg_get_functiondef('public.sync_health()'::regprocedure);
  if position($q$('offlimit','reconcile',1560,3000,false)$q$ in def) = 0 then
    raise exception 'expected offlimit threshold row not found';
  end if;
  execute replace(def, $q$('offlimit','reconcile',1560,3000,false)$q$,
                       $q$('offlimit','reconcile',120,240,false)$q$);
end $$;
