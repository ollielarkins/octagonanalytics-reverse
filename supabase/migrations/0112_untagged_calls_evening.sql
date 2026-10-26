-- 0112_untagged_calls_evening.sql
-- Priority 2 (Bhav, 20/10/2026): an end-of-day prompt to tag calls, because BD and client call KPIs
-- count only categorised calls and 7% of calls of 30 seconds or more were categorised in the 30 days
-- to 26/10/2026. The 17:30 Day End brief gets one line per consultant with today's untagged calls,
-- contact calls first (those are the ones the KPIs miss), pointing at /tagcalls.

-- untagged_calls_digest(p_day): per active consultant, untagged calls of 30 seconds or more on that
-- UK calendar day, split into contact and candidate calls.
create or replace function public.untagged_calls_digest(p_day date default (now() at time zone 'Europe/London')::date)
returns jsonb language sql stable security definer set search_path = public, pg_temp
as $function$
  with c as (
    select ca.consultant_recruitcrm_id, ca.related_to_type
    from call_activity ca
    where ca.custom_call_type is null and ca.duration_seconds >= 30
      and (ca.call_started_on at time zone 'Europe/London')::date = p_day
  ),
  per as (
    select co.name consultant,
           count(*) filter (where c.related_to_type = 'contact') contact_calls,
           count(*) filter (where c.related_to_type is distinct from 'contact') other_calls
    from c join consultants co on co.recruitcrm_id = c.consultant_recruitcrm_id
      and co.deleted_at is null and coalesce(co.active, true)
    group by co.name
  )
  select jsonb_build_object(
    'day', p_day,
    'contact_calls', coalesce((select sum(contact_calls) from per), 0),
    'other_calls', coalesce((select sum(other_calls) from per), 0),
    'by_consultant', coalesce((select jsonb_agg(jsonb_build_object('consultant', consultant,
        'contact_calls', contact_calls, 'other_calls', other_calls)
        order by contact_calls desc, other_calls desc, consultant) from per), '[]'::jsonb));
$function$;
revoke execute on function public.untagged_calls_digest(date) from public, anon, authenticated;
grant execute on function public.untagged_calls_digest(date) to service_role;

-- post_digest('evening'): the untagged-calls section after the calls summary, before new jobs.
-- Guarded like 0110: fail loudly if the brief has changed.
do $do$
declare
  def text := pg_get_functiondef('public.post_digest(text)'::regprocedure);
  anchor text := $a$    n := jsonb_array_length(d->'new_jobs');$a$;
  addition text := $b$    -- 0112: today's untagged calls per consultant, contact calls first.
    uc := public.untagged_calls_digest();
    if jsonb_array_length(uc->'by_consultant') > 0 then
      select string_agg('• *'||public.slack_escape(x->>'consultant')||'* — '||
               (x->>'contact_calls')||' contact · '||(x->>'other_calls')||' candidate', E'\n')
        into body from (select x from jsonb_array_elements(uc->'by_consultant') x limit 15) s;
      blocks := blocks || public.slack_section('*Untagged calls today* (30 seconds or more)'||E'\n'||body||
        E'\n_Only contact calls tagged BD or Client count toward the call targets. `/tagcalls` in Claude suggests a category for each and sets them in one go._');
    end if;

$b$;
begin
  if position('public.untagged_calls_digest()' in def) > 0 then
    return;   -- already applied
  end if;
  if (length(def) - length(replace(def, anchor, ''))) / length(anchor) <> 1 then
    raise exception '0112: post_digest evening anchor not found exactly once; the Day End brief has changed since 26/10/2026';
  end if;
  def := replace(def, anchor, addition || anchor);
  def := replace(def, 'n int; dd jsonb;', 'n int; dd jsonb; uc jsonb;');
  if position('uc jsonb;' in def) = 0 then
    raise exception '0112: post_digest declare block not found';
  end if;
  execute def;
end;
$do$;
