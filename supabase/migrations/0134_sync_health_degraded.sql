-- 0134_sync_health_degraded.sql
-- Partial failures count as unhealthy, not just statuses that start with "error:".
--
-- Found in the platform audit, 29/10/2026. Most feeds are strict_status = false, and error_count
-- only counted statuses starting "error:", so these all showed green while a feed did nothing useful:
--   - a reconcile that skipped on a partial fetch ("complete":false), or whose RPC failed (the
--     error lands as a string in "result"): deletes stop being detected;
--   - history_recent, notes and the incremental feeds stopped by a 429 ("stopped:...");
--   - meetings with failed owners ("partial:N_failed");
--   - a candidate pass whose retire step failed ("complete retired=error:...");
--   - an incremental walk cut short by the page cap ("page_cap...");
--   - the off-limit list possibly truncated ("possibly_truncated").
-- sync_status_degraded() names them. One degraded run warns; the error_count trigger now counts
-- them too, so two in a row go critical and alert, exactly as errors already do (0124).

create or replace function public.sync_status_degraded(p_entity text, p_status text)
returns boolean
language sql
immutable
set search_path = public, pg_temp
as $$
  select p_status is not null and (
       p_status like 'stopped:%'
    or p_status like 'partial:%'
    or p_status like 'page_cap%'
    or p_status like 'complete retired=error:%'
    or p_status like '%possibly_truncated%'
    or (p_entity like 'reconcile:%' and (p_status like '%"complete":false%' or p_status like '%"result":"%'))
  );
$$;
revoke execute on function public.sync_status_degraded(text, text) from public, anon, authenticated;

create or replace function public.sync_state_count_errors()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if new.last_status like 'error:%' or public.sync_status_degraded(new.entity, new.last_status) then
    new.error_count := case when tg_op = 'INSERT' then 1 else coalesce(old.error_count, 0) + 1 end;
  else
    new.error_count := 0;
  end if;
  return new;
end;
$$;

-- Guarded edits per 0083.
do $$
declare
  def text;
  new_def text;
  r record;
begin
  select pg_get_functiondef('public.sync_health'::regproc) into def;
  new_def := def;
  for r in select * from (values
    ($a$coalesce(s.error_count, 0) as error_count,$a$,
     $b$coalesce(s.error_count, 0) as error_count, public.sync_status_degraded(c.entity, s.last_status) as degraded,$b$),
    ($a$        when mins >= warn_min then 'warn'
        else 'ok'$a$,
     $b$        -- 0134: a partial failure on a non-strict feed (skipped reconcile, 429 stop, failed page).
        when degraded then 'warn'
        when mins >= warn_min then 'warn'
        else 'ok'$b$),
    ($a$        when mins >= warn_min then 'slowing: '||mins||' min since last run'$a$,
     $b$        when degraded then 'degraded: '||left(last_status, 120)
        when mins >= warn_min then 'slowing: '||mins||' min since last run'$b$)
  ) v(old_text, new_text) loop
    if position(r.old_text in new_def) = 0 then raise exception '0134: sync_health no longer contains: %', r.old_text; end if;
    new_def := replace(new_def, r.old_text, r.new_text);
  end loop;
  execute new_def;
end $$;
