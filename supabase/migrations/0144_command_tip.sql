-- 0144_command_tip.sql
-- One command to try, picked from the consultant's own data, for "your day" (my_day, octagon-mcp
-- 3.99.0). The command gap review (03/11/2026) found the commands that would help most were barely
-- used: /won and /newdeal 0 calls, /billing, /stalled, /bd 1-3, and the new /aftercare, /silver,
-- /lapsed, /hygiene and /jdcheck none yet. A static "command of the week" (the coach's) ignores
-- whether the command has anything to show this person; this one only suggests a command when
-- their own records give it a reason, in money-first order, and skips any they have used in the
-- last 28 days. At most one tip: nudge, don't nag. Checks stop at the first that applies.

create or replace function public.command_tip(p_consultant_id bigint)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  me record;
  used text[];
  n int;
  h jsonb;
  chk jsonb;
begin
  select id, name into me from consultants where recruitcrm_id = p_consultant_id and deleted_at is null;
  if me.name is null then return null; end if;
  select coalesce(array_agg(distinct tool), '{}') into used from mcp_call_log
    where consultant_recruitcrm_id = p_consultant_id and created_at > now() - interval '28 days';

  -- 1. Money not recorded: a placement with no Won deal, or a Won deal at £0.
  if not ('update_deal' = any(used) or 'create_deal' = any(used)) then
    h := data_hygiene(null, null, me.name, 1);
    select coalesce(sum((c->>'count')::int), 0) into n from jsonb_array_elements(h->'checks') c
      where c->>'check' in ('placed_no_won_deal', 'won_no_value');
    if n > 0 then
      return jsonb_build_object('command', '/won', 'tool', 'update_deal', 'count', n,
        'why', n || ' placement' || case when n = 1 then '' else 's' end || ' with no Won deal or no value, so billing is missing ' || case when n = 1 then 'it' else 'them' end);
    end if;
  end if;

  -- 2. Placements needing a call.
  if not ('aftercare' = any(used)) then
    n := coalesce((aftercare(me.name)->'counts'->>'overdue_no_contact')::int, 0);
    if n > 0 then
      return jsonb_build_object('command', '/aftercare', 'tool', 'aftercare', 'count', n,
        'why', n || ' check-in' || case when n = 1 then '' else 's' end || ' overdue on your placements');
    end if;
  end if;

  -- 3. Won deals with gaps that make fee figures wrong.
  if not ('data_hygiene' = any(used)) then
    h := coalesce(h, data_hygiene(null, null, me.name, 1));
    select coalesce(sum((c->>'count')::int), 0) into n from jsonb_array_elements(h->'checks') c
      where c->>'check' in ('won_no_fee_pct', 'won_no_salary', 'won_salary_in_thousands', 'won_no_start_date');
    if n > 0 then
      return jsonb_build_object('command', '/hygiene', 'tool', 'data_hygiene', 'count', n,
        'why', n || ' gap' || case when n = 1 then '' else 's' end || ' on your Won deals (fee %, salary or start date)');
    end if;
  end if;

  -- 4. Interview-tested candidates free again.
  if not ('silver_medallists' = any(used)) then
    n := coalesce((silver_medallists(null, null, me.name, 1)->'counts'->>'available')::int, 0);
    if n > 0 then
      return jsonb_build_object('command', '/silver', 'tool', 'silver_medallists', 'count', n,
        'why', n || ' candidate' || case when n = 1 then '' else 's' end || ' who reached 2nd interview or offer with you are free again, with open roles to fit');
    end if;
  end if;

  -- 5. Open jobs Claude has no spec for.
  if not ('internal_jd_check' = any(used)) then
    select count(*) into n from jobs j
      where j.consultant_id = me.id and j.deleted_at is null and j.status = 'Open'
        and coalesce(trim(j.custom_fields->'3'->>'value'), '') = '';
    if n > 0 then
      return jsonb_build_object('command', '/jdcheck', 'tool', 'internal_jd_check', 'count', n,
        'why', n || ' of your open jobs ha' || case when n = 1 then 's' else 've' end || ' no Internal JD, so adverts and matching have nothing to work from');
    end if;
  end if;

  -- 6. Past clients gone quiet.
  if not ('lapsed_clients' = any(used)) then
    n := coalesce((lapsed_clients(6, me.name, 1)->'counts'->>'available')::int, 0);
    if n > 0 then
      return jsonb_build_object('command', '/lapsed', 'tool', 'lapsed_clients', 'count', n,
        'why', n || ' past client' || case when n = 1 then '' else 's' end || ' with no new job in 6 months: warm BD calls');
    end if;
  end if;

  -- 7. Candidates gone quiet on open roles.
  if not ('stalled_report' = any(used)) then
    select count(*) into n from jsonb_array_elements(stalled_report()->'stalled') s where s->>'consultant' = me.name;
    if n > 0 then
      return jsonb_build_object('command', '/stalled', 'tool', 'stalled_report', 'count', n,
        'why', n || ' candidate' || case when n = 1 then '' else 's' end || ' gone quiet on your open roles');
    end if;
  end if;

  return null;
end;
$function$;
revoke execute on function public.command_tip(bigint) from public, anon, authenticated;
grant execute on function public.command_tip(bigint) to service_role;
