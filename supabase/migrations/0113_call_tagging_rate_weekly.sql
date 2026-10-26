-- 0113_call_tagging_rate_weekly.sql
-- Priority 2 (Bhav, 20/10/2026): "weekly tagging rate per consultant to track improvement". The
-- Monday Week Ahead brief gets each consultant's share of calls tagged last week, against the week
-- before, so /tagcalls (octagon-mcp 3.76.0) can be seen working, or not.

-- call_tagging_rates(p_week_start): calls of 30 seconds or more per active consultant in the UK week
-- starting p_week_start (a Monday) and the week before it, with the share categorised.
create or replace function public.call_tagging_rates(p_week_start date default (date_trunc('week', (now() at time zone 'Europe/London')::date) - interval '7 days')::date)
returns jsonb language sql stable security definer set search_path = public, pg_temp
as $function$
  with c as (
    select ca.consultant_recruitcrm_id,
           case when (ca.call_started_on at time zone 'Europe/London')::date >= p_week_start then 'this' else 'prev' end wk,
           ca.custom_call_type is not null tagged
    from call_activity ca
    where ca.duration_seconds >= 30
      and (ca.call_started_on at time zone 'Europe/London')::date >= p_week_start - 7
      and (ca.call_started_on at time zone 'Europe/London')::date <  p_week_start + 7
  ),
  per as (
    select co.name consultant,
           count(*) filter (where wk = 'this') calls,
           count(*) filter (where wk = 'this' and tagged) tagged,
           count(*) filter (where wk = 'prev') prev_calls,
           count(*) filter (where wk = 'prev' and tagged) prev_tagged
    from c join consultants co on co.recruitcrm_id = c.consultant_recruitcrm_id
      and co.deleted_at is null and coalesce(co.active, true)
    group by co.name
  )
  select jsonb_build_object(
    'week_start', p_week_start,
    'firm', (select jsonb_build_object('calls', sum(calls), 'tagged', sum(tagged),
        'pct', round(100.0 * sum(tagged) / nullif(sum(calls), 0), 1),
        'prev_pct', round(100.0 * sum(prev_tagged) / nullif(sum(prev_calls), 0), 1)) from per),
    'by_consultant', coalesce((select jsonb_agg(jsonb_build_object('consultant', consultant,
        'calls', calls, 'tagged', tagged,
        'pct', round(100.0 * tagged / nullif(calls, 0), 1),
        'prev_pct', round(100.0 * prev_tagged / nullif(prev_calls, 0), 1))
        order by round(100.0 * tagged / nullif(calls, 0), 1) desc nulls last, consultant)
      from per where calls > 0), '[]'::jsonb));
$function$;
revoke execute on function public.call_tagging_rates(date) from public, anon, authenticated;
grant execute on function public.call_tagging_rates(date) to service_role;

-- post_digest('weekly'): the tagging-rate section before the cold roles. Guarded like 0110 and 0112.
do $do$
declare
  def text := pg_get_functiondef('public.post_digest(text)'::regprocedure);
  anchor text := $a$    body := public.slack_cold_roles(d->'cold_roles', 10);$a$;
  addition text := $b$    -- 0113: last week's call tagging rate per consultant, against the week before.
    tr := public.call_tagging_rates();
    if jsonb_array_length(tr->'by_consultant') > 0 then
      select string_agg('• '||public.slack_escape(x->>'consultant')||' — '||coalesce(x->>'pct','0')||'% of '||
               (x->>'calls')||' calls'||
               case when x->>'prev_pct' is null then ''
                    else ' ('||case when (x->>'pct')::numeric > (x->>'prev_pct')::numeric then 'up from '
                                    when (x->>'pct')::numeric < (x->>'prev_pct')::numeric then 'down from '
                                    else 'same as ' end||(x->>'prev_pct')||'%)' end, E'\n')
        into body from (select x from jsonb_array_elements(tr->'by_consultant') x limit 15) s;
      blocks := blocks || public.slack_section('*Calls tagged last week* — firm '||
        coalesce(tr->'firm'->>'pct','0')||'%'||coalesce(' (week before '||(tr->'firm'->>'prev_pct')||'%)','')||E'\n'||body||
        E'\n_Calls of 30 seconds or more. Only tagged BD and client calls count toward the targets; `/tagcalls` does a day in a minute._');
    end if;

$b$;
begin
  if position('public.call_tagging_rates()' in def) > 0 then
    return;   -- already applied
  end if;
  if (length(def) - length(replace(def, anchor, ''))) / length(anchor) <> 1 then
    raise exception '0113: post_digest weekly anchor not found exactly once; the Week Ahead brief has changed since 26/10/2026';
  end if;
  def := replace(def, anchor, addition || anchor);
  def := replace(def, 'n int; dd jsonb; uc jsonb;', 'n int; dd jsonb; uc jsonb; tr jsonb;');
  if position('tr jsonb;' in def) = 0 then
    raise exception '0113: post_digest declare block not found';
  end if;
  execute def;
end;
$do$;
