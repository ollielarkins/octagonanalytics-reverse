-- 0117_action_queue_cleanup_wording.sql
-- 0116's clean-up line read "1 stages look out of date" for a single stale stage (Will Drake,
-- 26/10/2026). Singular for one, plural otherwise. Guarded edit of action_queue: nothing else changes.
do $do$
declare
  def text := pg_get_functiondef('public.action_queue(bigint)'::regprocedure);
  old text := $a$(select count(*) from stale)||' stages look out of date$a$;
  new text := $b$(select count(*) from stale)||case when (select count(*) from stale) = 1 then ' stage looks' else ' stages look' end||' out of date$b$;
begin
  if position('stage looks' in def) > 0 then
    return;   -- already applied
  end if;
  if (length(def) - length(replace(def, old, ''))) / length(old) <> 1 then
    raise exception '0117: clean-up wording not found exactly once; action_queue has changed since 0116';
  end if;
  execute replace(def, old, new);
end;
$do$;
