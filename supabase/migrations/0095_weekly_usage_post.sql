-- Weekly Claude usage table, posted to #claude-int every Friday at 16:00 London time.
--
-- One post: a usage table per person (status, chats, tool calls and the change on last week,
-- active days, writes, errors), each person's most-used features, and the /map grid of feature
-- areas used / tried / never. Built from usage_report and team_insights, so it agrees with
-- /usage and /map. Admin and leavers without a token are left out; a leaver who still holds a
-- token is shown, tagged, because that is an access problem.
--
-- Mannerisms and way of speaking are NOT included yet. The platform records what kind of action
-- someone took and when, never what they typed, and their Claude chats are private to them, so
-- there is no source text. The post says so rather than leaving it out silently.
--
-- Posts to app_settings 'usage_webhook_url' (a Slack incoming webhook for #claude-int). Until that
-- is set it posts nothing and returns the would-be message, so it can be previewed:
--   select public.weekly_usage_post(false);
create or replace function public.weekly_usage_post(p_post boolean default true)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare
  f date := date_trunc('week', current_date)::date;
  t date := current_date + 1;
  u jsonb; pv jsonb; m jsonb; hook text; blocks jsonb; header text;
  t1 text; t2 text; tops text;
  areas text[] := array['dashboard','reporting','chasing','lookup','matching','changes','email','inbox','content'];
begin
  u  := public.usage_report(f, t, null);
  pv := public.usage_report(f - 7, f, null);
  m  := public.team_insights(f, t)->'feature_map';
  header := 'Claude usage: week from '||to_char(f, 'DD/MM/YYYY');

  with p as (
    select x->>'name' name, coalesce((x->>'left')::boolean, false) left_,
      case x->>'status' when 'active' then 'active'
                        when 'connected, never used a tool' then 'connected, no use'
                        when 'never connected' then 'never connected'
                        else left(x->>'status', 20) end status,
      coalesce((x->>'sessions')::int, 0) chats, coalesce((x->>'tool_calls')::int, 0) calls,
      coalesce((x->>'active_days')::int, 0) days, coalesce((x->>'writes')::int, 0) writes,
      coalesce((x->>'errors')::int, 0) errs, coalesce(x->'top_tools', '[]'::jsonb) tops
    from jsonb_array_elements(u->'people') x
    where x->>'name' <> 'Admin'
      and not (coalesce((x->>'left')::boolean, false) and coalesce((x->>'active_tokens')::int, 0) = 0)
  ), prev as (
    select x->>'name' name, coalesce((x->>'tool_calls')::int, 0) calls from jsonb_array_elements(pv->'people') x
  )
  select
    string_agg(rpad(left(p.name || case when p.left_ then ' (left)' else '' end, 22), 23) || rpad(p.status, 21)
      || lpad(p.chats::text, 6) || lpad(p.calls::text, 6)
      || lpad(case when p.calls - coalesce(pr.calls, 0) > 0 then '+' else '' end || (p.calls - coalesce(pr.calls, 0))::text, 7)
      || lpad(p.days::text, 5) || lpad(p.writes::text, 7) || lpad(p.errs::text, 7),
      E'\n' order by p.calls desc, p.name),
    string_agg(case when jsonb_array_length(p.tops) > 0 then '• *'||public.slack_escape(p.name)||'*: '
      ||(select string_agg(replace(v, '_', ' '), ', ') from jsonb_array_elements_text(p.tops) v) end,
      E'\n' order by p.calls desc, p.name)
  into t1, tops
  from p left join prev pr on pr.name = p.name;

  t1 := rpad('Name', 23)||rpad('Status', 21)||lpad('Chats', 6)||lpad('Calls', 6)||lpad('vs LW', 7)
        ||lpad('Days', 5)||lpad('Writes', 7)||lpad('Errors', 7)||E'\n'||coalesce(t1, '(no one)');

  select string_agg(rpad(left(x->>'name', 20), 21)
      || (select string_agg(case x->'areas'->>a when 'used' then '●' when 'tried' then '◐' else '·' end, '   ' order by o)
          from unnest(areas) with ordinality as z(a, o)),
      E'\n' order by x->>'name')
  into t2
  from jsonb_array_elements(m->'people') x
  where not coalesce((x->>'left')::boolean, false);
  t2 := rpad('', 21)||'Dsh Rep Chs Lkp Mat Chg Eml Inb Cnt'||E'\n'||coalesce(t2, '(no one)');

  blocks := jsonb_build_array(
    jsonb_build_object('type', 'header', 'text', jsonb_build_object('type', 'plain_text', 'text', left(header, 150))),
    public.slack_section('*Usage this week*'||E'\n```'||t1||'```'),
    public.slack_section('*Most-used features*'||E'\n'||coalesce(tops, '_none_')),
    public.slack_section('*Feature map*  ● used 3+ times  ◐ tried  · never'||E'\n```'||t2||'```'
      ||E'\n_Dsh dashboard · Rep reporting · Chs chasing · Lkp lookup · Mat matching · Chg changes · Eml email · Inb inbox · Cnt content_'),
    public.slack_context('Counts only use of the Octagon connector, Monday to Friday. vs LW = change in tool calls on last week.'
      ||' Mannerisms and way of speaking are not included yet: the platform does not record what people type.'));

  if not p_post then
    return jsonb_build_object('posted', false, 'reason', 'preview', 'header', header, 'blocks', blocks);
  end if;
  select value into hook from app_settings where key = 'usage_webhook_url' and coalesce(value, '') <> '';
  if hook is null then
    return jsonb_build_object('posted', false, 'reason', 'no usage_webhook_url set', 'header', header);
  end if;
  perform net.http_post(url := hook, headers := '{"Content-Type":"application/json"}'::jsonb,
    body := jsonb_build_object('text', header, 'blocks', blocks));
  return jsonb_build_object('posted', true, 'header', header);
end;
$function$;

-- Two UTC hours so 16:00 London lands in both BST and GMT; post only in the right one.
create or replace function public.weekly_usage_post_if_due()
returns void language plpgsql security definer set search_path to 'public' as $function$
begin
  if extract(hour from (now() at time zone 'Europe/London'))::int <> 16 then return; end if;
  perform public.weekly_usage_post(true);
end;
$function$;

revoke all on function public.weekly_usage_post(boolean) from public, anon, authenticated;
revoke all on function public.weekly_usage_post_if_due() from public, anon, authenticated;

select cron.schedule('weekly-usage-slack', '0 15,16 * * 5', 'select public.weekly_usage_post_if_due();');
