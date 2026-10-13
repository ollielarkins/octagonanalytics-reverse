-- 0087_team_insights.sql
-- Team-level views of how consultants use the platform, for admins: feature map, adoption trend,
-- habits, coaching suggestions and onboarding progress. Read by the admin-only team_insights tool
-- (/team, /map, /adoption, /habits, /coach in the octagon-admin plugin).
--
-- Built on mcp_call_log + audit_log + mcp_tokens, like usage_report (0086). Content work
-- (adverts, Boolean, spec pitches...) is counted from octagon-mcp 3.48.0: content skills call
-- record_content_use (logged as 'content:<kind>') and server prompt templates log 'prompt:<name>'.
--
-- The admin identity (consultant id 0) is left out: these are views of the team.
-- Shows kinds of action and when, never record content.

-- Which part of the product a tool belongs to. One place, so /map, /coach and onboarding agree.
create or replace function public.feature_area(p_tool text)
returns text language sql immutable as $function$
  select case
    when p_tool = '_session' then null
    when p_tool like 'content:%' or p_tool like 'prompt:%' then 'content'
    when p_tool in ('get_dashboard','weekly_kpis','billing','my_day') then 'dashboard'
    when p_tool in ('stalled_report','cold_jobs','awaiting_feedback_report','interview_requests_unbooked') then 'chasing'
    when p_tool = 'match_candidates' then 'matching'
    when p_tool in ('find_candidate','candidate_profile','job_pipeline','notes_read','files_list','pitch_history','reference_list','off_limit') then 'lookup'
    when p_tool in ('update_hiring_stage','assign_candidate','add_note','create_candidate','update_candidate','create_job','update_job',
                    'create_deal','update_deal','manage_client','manage_assignment','log_activity','hotlist','pitch_candidate','delete_record') then 'changes'
    when p_tool = 'send_email' then 'email'
    when p_tool in ('inbox','draft_reply') then 'inbox'
    when p_tool in ('usage_report','manage_tokens','platform_health','webhook_subscriptions','post_digest','team_insights') then 'admin'
    else 'reporting' end
$function$;

create or replace function public.team_insights(p_from date default (current_date - 28), p_to date default (current_date + 1))
returns jsonb
-- volatile, not stable: it builds temp tables. Read-only in effect; it writes nothing persistent.
language plpgsql volatile security definer set search_path to 'public'
as $function$
declare
  v_weeks numeric := greatest(1, (p_to - p_from) / 7.0);
  v_areas text[] := array['dashboard','reporting','chasing','lookup','matching','changes','email','inbox','content'];
  v_kpis jsonb;
  v_map jsonb; v_adoption jsonb; v_habits jsonb; v_coach jsonb; v_onboarding jsonb; v_headline jsonb;
begin
  begin v_kpis := public.kpis_report(); exception when others then v_kpis := null; end;
  drop table if exists ti_people, ti_calls_all, ti_calls, ti_onb;

  -- People in view: anyone holding an active token, plus anyone who used it in the window (leavers
  -- included and tagged). Admin (0) excluded.
  create temp table ti_people on commit drop as
    select n.id, coalesce(c.name, 'user ' || n.id) as name, coalesce(c.active, false) = false as has_left,
      exists (select 1 from mcp_tokens t where t.consultant_recruitcrm_id = n.id and t.active) as has_access,
      (select bool_or(t.can_write) from mcp_tokens t where t.consultant_recruitcrm_id = n.id and t.active) as can_write,
      (select max(t.last_used_at) from mcp_tokens t where t.consultant_recruitcrm_id = n.id) as last_connected
    from (select consultant_recruitcrm_id id from mcp_tokens where active
          union select consultant_recruitcrm_id from mcp_call_log
                where created_at >= p_from and created_at < p_to and consultant_recruitcrm_id is not null) n
    left join consultants c on c.recruitcrm_id = n.id
    where n.id <> 0;

  create temp table ti_calls_all on commit drop as
    select l.consultant_recruitcrm_id id, l.tool, l.ok, l.created_at, public.feature_area(l.tool) area,
           (l.created_at at time zone 'Europe/London') local_ts
    from mcp_call_log l where l.consultant_recruitcrm_id in (select id from ti_people);
  create temp table ti_calls on commit drop as
    select * from ti_calls_all where created_at >= p_from and created_at < p_to and area is not null and area <> 'admin';

  -- FEATURE MAP: per person, per area: used (3+ calls), tried (1-2), never.
  select jsonb_build_object(
    'areas', to_jsonb(v_areas),
    'people', coalesce(jsonb_agg(jsonb_build_object('name', p.name, 'left', p.has_left, 'areas', (
        select jsonb_object_agg(a, case when n >= 3 then 'used' when n >= 1 then 'tried' else 'never' end)
        from (select a, (select count(*) from ti_calls k where k.id = p.id and k.area = a) n from unnest(v_areas) a) x))
      order by p.has_left, p.name), '[]'::jsonb),
    'by_area', (select jsonb_object_agg(a, (select count(distinct k.id) from ti_calls k where k.area = a)) from unnest(v_areas) a),
    'unused_by_everyone', (select coalesce(jsonb_agg(a), '[]'::jsonb) from unnest(v_areas) a where not exists (select 1 from ti_calls k where k.area = a)))
  into v_map from ti_people p;

  -- ADOPTION: weekly active users, first-timers, and drop-offs (used it in the window, quiet for 14+ days).
  select jsonb_build_object(
    'with_access', (select count(*) from ti_people where has_access and not has_left),
    'weekly', (select coalesce(jsonb_agg(jsonb_build_object('week_start', wk, 'active_users', au, 'new_users', nu, 'tool_calls', tc) order by wk), '[]'::jsonb) from (
        select date_trunc('week', k.created_at)::date wk, count(distinct k.id) au, count(*) tc,
          count(distinct k.id) filter (where date_trunc('week', f.first_at) = date_trunc('week', k.created_at)) nu
        from ti_calls k join (select id, min(created_at) first_at from ti_calls_all where area is not null group by id) f using (id)
        group by 1) w),
    'dropped_off', (select coalesce(jsonb_agg(jsonb_build_object('name', p.name, 'last_used', l) order by l desc), '[]'::jsonb) from (
        select p.name, max(k.created_at)::date l from ti_people p join ti_calls k on k.id = p.id
        where not p.has_left group by p.name having max(k.created_at) < now() - interval '14 days') p),
    'never_started', (select coalesce(jsonb_agg(p.name order by p.name), '[]'::jsonb) from ti_people p
        where p.has_access and not p.has_left and not exists (select 1 from ti_calls_all k where k.id = p.id and k.area is not null)))
  into v_adoption;

  -- HABITS: rhythm per active person (London time).
  select coalesce(jsonb_agg(jsonb_build_object(
      'name', name, 'active_days', d, 'days_per_week', round(d / v_weeks, 1),
      'pattern', case when d / v_weeks >= 4 then 'daily' when d / v_weeks >= 1 then 'weekly' else 'occasional' end,
      'morning_starts', ms, 'busiest_hours', hrs, 'weekdays', wd) order by d desc), '[]'::jsonb)
  into v_habits from (
    select p.name,
      count(distinct k.local_ts::date) d,
      count(distinct k.local_ts::date) filter (where k.area = 'dashboard' and extract(hour from k.local_ts) < 10) ms,
      jsonb_build_object(
        'before_9',  count(*) filter (where extract(hour from k.local_ts) < 9),
        '9_to_12',   count(*) filter (where extract(hour from k.local_ts) between 9 and 11),
        '12_to_14',  count(*) filter (where extract(hour from k.local_ts) between 12 and 13),
        '14_to_17',  count(*) filter (where extract(hour from k.local_ts) between 14 and 16),
        'after_17',  count(*) filter (where extract(hour from k.local_ts) >= 17)) hrs,
      jsonb_build_object(
        'mon', count(*) filter (where extract(isodow from k.local_ts) = 1), 'tue', count(*) filter (where extract(isodow from k.local_ts) = 2),
        'wed', count(*) filter (where extract(isodow from k.local_ts) = 3), 'thu', count(*) filter (where extract(isodow from k.local_ts) = 4),
        'fri', count(*) filter (where extract(isodow from k.local_ts) = 5), 'weekend', count(*) filter (where extract(isodow from k.local_ts) >= 6)) wd
    from ti_people p join ti_calls k on k.id = p.id group by p.name) h;

  -- ONBOARDING: the Day 1-5 plan in docs/wiki/Onboarding.md, plus a first change. All-time, not windowed.
  create temp table ti_onb on commit drop as
    select p.id, p.name, p.has_left, p.can_write,
      (p.last_connected is not null or exists (select 1 from ti_calls_all k where k.id = p.id)) connected,
      exists (select 1 from ti_calls_all k where k.id = p.id and k.tool in ('get_dashboard','my_day')) desk,
      exists (select 1 from ti_calls_all k where k.id = p.id and k.tool in ('weekly_kpis','billing','cold_jobs','funnel_report')) numbers,
      exists (select 1 from ti_calls_all k where k.id = p.id and k.tool in ('job_pipeline','client_report')) live_role,
      exists (select 1 from ti_calls_all k where k.id = p.id and (k.area = 'content' or k.tool = 'match_candidates')) content,
      exists (select 1 from ti_calls_all k where k.id = p.id and k.tool in ('prompt:job_kickoff','content:job_kickoff')) kickoff,
      exists (select 1 from audit_log a where a.actor = p.id::text) first_change
    from ti_people p where not p.has_left;
  select coalesce(jsonb_agg(jsonb_build_object('name', name,
      'steps', jsonb_build_object('connected', connected, 'desk', desk, 'numbers', numbers, 'live_role', live_role,
                                  'content', content, 'kickoff', kickoff, 'first_change', first_change),
      'done', (connected::int + desk::int + numbers::int + live_role::int + content::int + kickoff::int + first_change::int),
      'next_step', case when not connected then 'Connect (Onboarding Part 1)' when not desk then 'Day 1: "show me my dashboard"'
                        when not numbers then 'Day 2: "how am I doing this week?"' when not live_role then 'Day 3: "what''s happening on <role>?"'
                        when not content then 'Day 4: paste a spec, ask for an advert or Boolean' when not kickoff then 'Day 5: "new job kickoff for <role>"'
                        when not first_change and can_write then 'Part 4: a first change, e.g. move a stage' else null end)
    order by (connected::int + desk::int + numbers::int + live_role::int + content::int + kickoff::int + first_change::int), name), '[]'::jsonb)
  into v_onboarding from ti_onb;

  -- COACH: this week's KPI gaps next to unused features, plus changes started and never confirmed.
  -- A write tool is normally called twice (preview, then confirm), so calls - 2 x applied writes
  -- approximates abandoned previews. Approximate by design: retries and errors inflate it.
  select coalesce(jsonb_agg(jsonb_build_object('name', name, 'behind', behind, 'unused', unused, 'unfinished_changes', unfinished,
      'suggestions', sugg) order by jsonb_array_length(sugg) desc, name), '[]'::jsonb)
  into v_coach from (
    select o.name, o.behind, o.unused, o.unfinished,
      (select coalesce(jsonb_agg(s), '[]'::jsonb) from (select s from unnest(array[
        case when not o.connected then 'Help them connect: Onboarding Part 1' end,
        case when o.connected and o.unused ? 'dashboard' then 'Start the day with "what''s my day" for the attention list' end,
        case when (o.behind ? 'cv_sent' or o.behind ? 'interview_request') and o.unused ? 'matching' then 'Show /match: CRM candidates for a live role in seconds' end,
        case when o.unused ? 'chasing' then 'Show /chase and /stalled: what to follow up today' end,
        case when o.unfinished > 0 then 'Started ' || o.unfinished || ' change(s) without confirming: walk through the preview-then-confirm step' end,
        case when o.can_write and o.unused ? 'changes' then 'Show /move: update a stage from chat' end,
        case when o.unused ? 'content' then 'Show /advert and /boolean from a pasted spec' end
      ]) s where s is not null limit 3) z) sugg
    from (
      select b.*,
        (select coalesce(jsonb_agg(m), '[]'::jsonb) from jsonb_array_elements(coalesce(v_kpis->'consultants', '[]'::jsonb)) e(kc),
           unnest(array['cv_sent','interview_request','first_interview','bd_calls','client_calls']) m
           where kc->>'name' = b.name and (kc->m->>'target') is not null and coalesce((kc->m->>'actual')::numeric, 0) < (kc->m->>'target')::numeric) behind,
        (select coalesce(jsonb_agg(a), '[]'::jsonb) from unnest(v_areas) a
           where a not in ('email','inbox','lookup','reporting') and not exists (select 1 from ti_calls_all k where k.id = b.id and k.area = a)) unused,
        (select coalesce(sum(greatest(c.n - 2 * coalesce(w.n, 0), 0)), 0)::int from
           (select k.tool, count(*) n from ti_calls k where k.id = b.id and k.area = 'changes' group by k.tool) c
           left join (select case when a.action in ('create_contact','update_contact','create_company','update_company') then 'manage_client' else a.action end tool, count(*) n
                      from audit_log a where a.actor = b.id::text and a.created_at >= p_from and a.created_at < p_to group by 1) w using (tool)) unfinished
      from ti_onb b) o) c;

  select jsonb_build_object(
    'active_in_window', (select count(distinct id) from ti_calls),
    'active_last_7d', (select count(distinct id) from ti_calls where created_at > now() - interval '7 days'),
    'active_prior_7d', (select count(distinct id) from ti_calls_all where area is not null and area <> 'admin'
                          and created_at > now() - interval '14 days' and created_at <= now() - interval '7 days'),
    'with_access', v_adoption->'with_access',
    'dropped_off', jsonb_array_length(v_adoption->'dropped_off'),
    'never_started', jsonb_array_length(v_adoption->'never_started'))
  into v_headline;

  return jsonb_build_object(
    'window', jsonb_build_object('from', p_from, 'to_exclusive', p_to),
    'headline', v_headline, 'feature_map', v_map, 'adoption', v_adoption, 'habits', v_habits,
    'onboarding', v_onboarding, 'coach', v_coach,
    'notes', jsonb_build_array(
      'Counts only use of the Octagon connector; admin use is excluded.',
      'Content work (adverts, Boolean, pitches) is counted from 13/10/2026; earlier content use is invisible.',
      'unfinished_changes is approximate: a change is normally previewed then confirmed, so it is write calls minus twice the applied changes.',
      'Usage is not performance. Coaching suggestions are where help would pay off, not a rating.'));
end
$function$;

revoke all on function public.team_insights(date, date) from public, anon, authenticated;
