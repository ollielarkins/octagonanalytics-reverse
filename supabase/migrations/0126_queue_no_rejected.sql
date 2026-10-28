-- 0126_queue_no_rejected.sql
-- Requested 28/10/2026: stop prompting action on rejected candidates. 0121 added a "Rejected by the
-- client: ask Claude to draft the candidate update" call to the 08:30 queue DM for client rejections
-- in the last 4 days with no note since. This removes that call kind from action_queue. The briefs
-- themselves never prompted on rejections, and rejection reporting (rejection_report, /rejections)
-- is unchanged. Guarded edit: fails if action_queue no longer matches 0121.
do $do$
declare
  def text := pg_get_functiondef('public.action_queue(bigint)'::regprocedure);
  a1 text := $a$  rejected as (
    select 4, 'rejected', 'rejected:'||e.candidate_slug||':'||e.job_slug, e.candidate_name, e.job_title, null::text, e.candidate_slug, e.job_slug,
           (current_date - e.event_date), 'Rejected by the client '||to_char(e.event_date, 'DD/MM')||': ask Claude to draft the candidate update'
    from (select distinct on (candidate_slug, job_slug) * from candidate_stage_events
          where stage_metric = 'rejected_client' and event_date >= current_date - 4
          order by candidate_slug, job_slug, event_timestamp desc) e, me
    where e.consultant = me.name
      and not exists (select 1 from notes n where n.related_to = e.candidate_slug and n.created_on >= (e.event_timestamp at time zone 'UTC'))
  ),
$a$;
  a2 text := $a$ union all select * from rejected) a$a$;
  n2 text := $b$) a$b$;
  a3 text := $a$ when 'rejected' then 3$a$;
  k text;
begin
  if position('  rejected as (' in def) = 0 then
    return;   -- already applied
  end if;
  foreach k in array array[a1, a2, a3] loop
    if (length(def) - length(replace(def, k, ''))) / length(k) <> 1 then
      raise exception '0126: action_queue anchor not found exactly once (%); it has changed since 0121', left(k, 40);
    end if;
  end loop;
  def := replace(def, a1, '');
  def := replace(def, a2, n2);
  def := replace(def, a3, '');
  if position('rejected' in def) > 0 then
    raise exception '0126: a rejected reference is still left in action_queue';
  end if;
  execute def;
end;
$do$;
