-- 0086_usage_report.sql
-- Per-person platform usage for admins: who uses the Octagon connector, how often, for what, and
-- what they change. Read by the admin-only usage_report tool in octagon-mcp (/usage in the
-- octagon-admin plugin).
--
-- Sources, all already recorded:
--   mcp_call_log  one row per tool call. From octagon-mcp 3.47.0, ok reflects the real outcome
--                 (before, every call was logged ok=true before it ran, so errors read as zero),
--                 and tool '_session' marks a chat opening the connector (initialize).
--   audit_log     one row per write made through Claude.
--   mcp_tokens    who holds access and when each token was last presented.
--
-- Shows what kind of action and when, never arguments or record content: the call log holds no
-- arguments, and writes are summarised by action type only.
-- Leavers are tagged (consultants.active = false), as dashboard_json does, never dropped.

create index if not exists mcp_call_log_consultant_created_idx on public.mcp_call_log (consultant_recruitcrm_id, created_at);
create index if not exists audit_log_actor_created_idx on public.audit_log (actor, created_at);

create or replace function public.usage_report(p_from date default (current_date - 28), p_to date default (current_date + 1), p_consultant text default null)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $function$
declare
  v_id bigint;
  v_name text;
  res jsonb;
begin
  if p_consultant is not null then
    if lower(trim(p_consultant)) = 'admin' then v_id := 0; v_name := 'Admin';
    else
      select recruitcrm_id, name into v_id, v_name from consultants
       where name ilike '%' || trim(p_consultant) || '%' order by active desc, name limit 1;
      if v_id is null then return jsonb_build_object('error', 'No consultant matches ''' || p_consultant || '''.'); end if;
    end if;
  end if;

  with people as (
    select consultant_recruitcrm_id id from mcp_tokens
    union select consultant_recruitcrm_id from mcp_call_log where consultant_recruitcrm_id is not null
  ),
  named as (
    select p.id,
      case when p.id = 0 then 'Admin' else coalesce(c.name, 'user ' || p.id) end as name,
      case when p.id = 0 then false else coalesce(c.active, false) = false end as has_left
    from people p left join consultants c on c.recruitcrm_id = p.id
  ),
  calls as (
    select * from mcp_call_log where created_at >= p_from and created_at < p_to
      and (v_id is null or consultant_recruitcrm_id = v_id)
  ),
  writes as (
    select * from audit_log where created_at >= p_from and created_at < p_to
      and actor ~ '^[0-9]+$' and (v_id is null or actor::bigint = v_id)
  ),
  per as (
    select n.id, n.name, n.has_left,
      (select count(*) from mcp_tokens t where t.consultant_recruitcrm_id = n.id and t.active) as active_tokens,
      (select bool_or(t.can_write) from mcp_tokens t where t.consultant_recruitcrm_id = n.id and t.active) as can_write,
      (select max(t.last_used_at) from mcp_tokens t where t.consultant_recruitcrm_id = n.id) as last_connected,
      (select count(*) from calls k where k.consultant_recruitcrm_id = n.id and k.tool <> '_session') as tool_calls,
      (select count(*) from calls k where k.consultant_recruitcrm_id = n.id and k.tool = '_session') as sessions,
      (select count(distinct date(k.created_at)) from calls k where k.consultant_recruitcrm_id = n.id) as active_days,
      (select count(*) from calls k where k.consultant_recruitcrm_id = n.id and not k.ok) as errors,
      (select max(k.created_at) from mcp_call_log k where k.consultant_recruitcrm_id = n.id and k.tool <> '_session') as last_tool_call,
      (select count(*) from writes w where w.actor::bigint = n.id) as writes,
      (select coalesce(jsonb_agg(x.tool order by x.n desc), '[]'::jsonb) from (
         select k.tool, count(*) n from calls k where k.consultant_recruitcrm_id = n.id and k.tool <> '_session'
         group by k.tool order by n desc limit 3) x) as top_tools
    from named n
    where v_id is null or n.id = v_id
  )
  select jsonb_build_object(
    'window', jsonb_build_object('from', p_from, 'to_exclusive', p_to),
    'scope', coalesce(v_name, 'everyone'),
    'people', (select coalesce(jsonb_agg(jsonb_build_object(
        'name', name, 'left', has_left, 'active_tokens', active_tokens, 'can_write', coalesce(can_write, false),
        'tool_calls', tool_calls, 'sessions', sessions, 'active_days', active_days, 'errors', errors, 'writes', writes,
        'top_tools', top_tools, 'last_tool_call', last_tool_call, 'last_connected', last_connected,
        'status', case
          when has_left and active_tokens > 0 then 'left — token still active'
          when last_tool_call is null and last_connected is null then 'never connected'
          when last_tool_call is null then 'connected, never used a tool'
          when tool_calls = 0 then 'inactive in window'
          else 'active' end)
      order by has_left, tool_calls desc, name), '[]'::jsonb) from per),
    'weekly', (select coalesce(jsonb_agg(jsonb_build_object('week_start', wk, 'name', name, 'tool_calls', n) order by wk, n desc), '[]'::jsonb) from (
        select date_trunc('week', k.created_at)::date wk, nm.name, count(*) n
        from calls k join named nm on nm.id = k.consultant_recruitcrm_id
        where k.tool <> '_session' group by 1, 2) w),
    'detail', case when v_id is null then null else jsonb_build_object(
        'tools', (select coalesce(jsonb_agg(jsonb_build_object('tool', tool, 'calls', n, 'errors', e) order by n desc), '[]'::jsonb) from (
            select tool, count(*) n, count(*) filter (where not ok) e from calls where tool <> '_session' group by tool) t),
        'daily', (select coalesce(jsonb_agg(jsonb_build_object('date', d, 'tool_calls', n, 'writes', w) order by d), '[]'::jsonb) from (
            select d, sum(n) n, sum(w) w from (
              select date(created_at) d, count(*) n, 0 w from calls where tool <> '_session' group by 1
              union all select date(created_at), 0, count(*) from writes group by 1) u group by d) dd),
        'writes_by_action', (select coalesce(jsonb_agg(jsonb_build_object('action', action, 'count', n, 'last', l) order by n desc), '[]'::jsonb) from (
            select action, count(*) n, max(created_at) l from writes group by action) a)
      ) end,
    'notes', jsonb_build_array(
      'Counts only use of the Octagon connector. Chats that never call it are not visible here.',
      'sessions counts chats that opened the connector; recorded from 13/10/2026 onwards.',
      'errors are recorded accurately from 13/10/2026; earlier calls all read as successful.',
      'All admin tokens share one identity (Admin).')
  ) into res;
  return res;
end
$function$;

revoke all on function public.usage_report(date, date, text) from public, anon, authenticated;
