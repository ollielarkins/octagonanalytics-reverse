-- 0129_coach.sql
-- The Octagon Coach (28/10/2026): a separate Slack app that DMs each pilot consultant short,
-- rule-based nudges built from their own numbers. No AI on the server (the 13/10/2026 rule): the rules
-- pick the nudge, and every suggestion names the command or prompt to use in the person's own Claude.
--   12:30 weekdays  midday: today so far against today's share of the plan, queue progress, up to 3
--                   things for the afternoon, and one command to try
--   16:45 weekdays  wrap-up: admin before home time, or a win; Fridays add the week against plan
--   08:45 Mondays   week ahead: the plan, billing pace, client visits
-- Guardrails: one suggestion per line, at most 3; skipped when they have already done it today;
-- gentle on Monday and Tuesday; only their own numbers; Pause for today and Mute this slot buttons.
-- Shadow mode first: every DM goes to coach_shadow_email, labelled.

insert into app_settings (key, value, updated_at) values
  ('coach_pilot', '154036,77535,77603,65639', now()),   -- Will Drake, Keelan Riley, Adam Barnett, Bhavesh Patel
  ('coach_shadow', 'true', now()),
  ('coach_shadow_email', 'olarkins@octagongroup.co.uk', now())
on conflict (key) do nothing;

-- Pause for today, or mute one slot. slot 'all' pauses everything until the date.
create table if not exists public.coach_pause (
  consultant_recruitcrm_id bigint not null,
  slot text not null,
  until date,                       -- null = muted until they unmute
  created_at timestamptz not null default now(),
  primary key (consultant_recruitcrm_id, slot)
);
alter table public.coach_pause enable row level security;
revoke all on table public.coach_pause from anon, authenticated;

-- What was suggested, so a week on we can see which nudges led to the command being used.
create table if not exists public.coach_log (
  id bigint generated always as identity primary key,
  consultant_recruitcrm_id bigint not null,
  slot text not null,
  sent_at timestamptz not null default now(),
  shadow boolean not null default false,
  suggested text[] not null default '{}'   -- the tools behind each suggestion, e.g. call_tagging
);
alter table public.coach_log enable row level security;
revoke all on table public.coach_log from anon, authenticated;

-- The message for one consultant and slot. Returns {skip:true} when paused or nothing to say.
create or replace function public.coach_nudges(p_consultant bigint, p_slot text)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp
as $function$
declare
  me record; plan jsonb; wk jsonb; q jsonb; dd jsonb; bill jsonb; vz jsonb;
  dow int := extract(isodow from (now() at time zone 'Europe/London'))::int;
  today date := (now() at time zone 'Europe/London')::date;
  cv int; ir int; iv int; calls int; untagged int; done_today int; open_items int;
  p_cv numeric; p_ir numeric; p_iv numeric; share_cv int; share_ir int; share_iv int;
  used_today text[]; used_28 text[];
  actions jsonb := '[]'::jsonb; suggested text[] := '{}'; stats jsonb; tip jsonb; headline text; quiet boolean := false;
  it jsonb; k int; overdue int; weeks_in int; exp_bill numeric;
begin
  select c.recruitcrm_id, c.name, split_part(c.name, ' ', 1) first_name into me
    from consultants c where c.recruitcrm_id = p_consultant and c.deleted_at is null;
  if me is null then return jsonb_build_object('skip', true, 'reason', 'no such consultant'); end if;
  if exists (select 1 from coach_pause where consultant_recruitcrm_id = p_consultant and slot in ('all', p_slot)
             and (until is null or until >= today)) then
    return jsonb_build_object('skip', true, 'reason', 'paused');
  end if;

  select x->'plan' into plan from jsonb_array_elements(public.weekly_plan(p_consultant)->'consultants') x limit 1;
  select x into wk from jsonb_array_elements(public.kpis_report()->'consultants') x where x->>'name' = me.name limit 1;
  p_cv := coalesce((plan->>'cv_sent')::numeric, 10); p_ir := coalesce((plan->>'interview_request')::numeric, 5); p_iv := coalesce((plan->>'first_interview')::numeric, 4);
  share_cv := ceil(p_cv / 5); share_ir := ceil(p_ir / 5); share_iv := ceil(p_iv / 5);

  -- Logged today, counted like the funnel: distinct candidate-job pairs, credited to whoever moved it.
  select count(distinct e.candidate_slug||'|'||e.job_slug) filter (where e.stage_metric = 'cv_sent'),
         count(distinct e.candidate_slug||'|'||e.job_slug) filter (where e.stage_metric = 'interview_request'),
         count(distinct e.candidate_slug||'|'||e.job_slug) filter (where e.stage_metric = 'first_interview')
    into cv, ir, iv from candidate_stage_events e where e.consultant = me.name and e.event_date = today;
  select count(*) into calls from call_activity where consultant_recruitcrm_id = p_consultant and call_started_on >= today and call_started_on < today + 1;
  select coalesce((x->>'contact_calls')::int, 0) + coalesce((x->>'other_calls')::int, 0) into untagged
    from jsonb_array_elements(public.untagged_calls_digest(today)->'by_consultant') x where x->>'consultant' = me.name;
  untagged := coalesce(untagged, 0);

  q := public.action_queue(p_consultant);
  select count(*) into done_today from action_queue_done where consultant_recruitcrm_id = p_consultant and done_at >= today::timestamptz;
  select count(*) into open_items from jsonb_array_elements(q->'items') i
    where i->>'kind' not in ('plan', 'cleanup', 'meetings', 'client_visits', 'pushtell');
  select array_agg(distinct tool) into used_today from mcp_call_log where consultant_recruitcrm_id = p_consultant and created_at >= today::timestamptz;
  select array_agg(distinct tool) into used_28 from mcp_call_log where consultant_recruitcrm_id = p_consultant and created_at >= now() - interval '28 days';
  used_today := coalesce(used_today, '{}'); used_28 := coalesce(used_28, '{}');
  select x into dd from jsonb_array_elements(public.diary_digest()->'by_consultant') x where x->>'consultant' = me.name limit 1;

  -- One suggestion: text, the prompt to use in Claude, and the tool behind it (for coach_log).
  -- Appended in priority order; the caller shows the first three.
  if p_slot = 'midday' then
    stats := jsonb_build_array(
      jsonb_build_object('label', 'CVs sent', 'value', cv || ' of ' || share_cv, 'ok', cv >= share_cv),
      jsonb_build_object('label', 'Interview requests', 'value', ir || ' of ' || share_ir, 'ok', ir >= share_ir),
      jsonb_build_object('label', 'Queue', 'value', done_today || ' done, ' || open_items || ' open', 'ok', open_items = 0),
      jsonb_build_object('label', 'Calls', 'value', calls || case when untagged > 0 then ' · ' || untagged || ' untagged' else '' end, 'ok', untagged = 0));
    for it in select i from jsonb_array_elements(q->'items') i where i->>'kind' = 'offer' limit 1 loop
      actions := actions || jsonb_build_object('text', it->>'action' || coalesce(' (' || (it->>'who') || ')', ''), 'prompt', 'prep my queue', 'tool', 'action_queue');
    end loop;
    if cv < share_cv then
      select i into it from jsonb_array_elements(q->'items') i where i->>'kind' = 'cold_job' limit 1;
      actions := actions || jsonb_build_object('text', (share_cv - cv) || case when share_cv - cv = 1 then ' more CV keeps' else ' more CVs keep' end
        || ' you on plan today' || coalesce(': start with ' || (it->>'job'), ''),
        'prompt', '/match ' || coalesce(it->>'job', 'my coldest role'), 'tool', 'match_candidates');
    end if;
    if exists (select 1 from jsonb_array_elements(q->'items') i where i->>'kind' = 'unbooked') and not ('interview_requests_unbooked' = any(used_today)) then
      actions := actions || jsonb_build_object('text', 'Interview requests waiting to be booked: draft the slot emails', 'prompt', '/unbooked', 'tool', 'interview_requests_unbooked');
    end if;
    if jsonb_array_length(coalesce(dd->'feedback_due', '[]')) > 0 and not ('awaiting_feedback_report' = any(used_today)) then
      actions := actions || jsonb_build_object('text', jsonb_array_length(dd->'feedback_due') || ' interviewed with no feedback logged', 'prompt', '/feedback', 'tool', 'awaiting_feedback_report');
    end if;
    if exists (select 1 from jsonb_array_elements(q->'items') i where i->>'kind' = 'bd') then
      actions := actions || jsonb_build_object('text', 'Behind on BD calls this week: a short target list and a spec pitch', 'prompt', '/bd', 'tool', 'bd_report');
    end if;
    if untagged >= 5 and not ('call_tagging' = any(used_today)) then
      actions := actions || jsonb_build_object('text', untagged || ' calls untagged so far, so they don''t count yet', 'prompt', '/tagcalls', 'tool', 'call_tagging');
    end if;
    headline := case when dow <= 2 then 'Your midday check, ' || me.first_name || '. Early in the week'
                     when cv >= share_cv and open_items = 0 then 'Your midday check, ' || me.first_name || '. On plan'
                     else 'Your midday check, ' || me.first_name end;
    quiet := cv >= share_cv and ir >= share_ir and open_items = 0 and jsonb_array_length(actions) = 0;

  elsif p_slot = 'wrap' then
    stats := jsonb_build_array(
      jsonb_build_object('label', 'Today', 'value', cv || ' CV · ' || ir || ' req · ' || iv || ' 1st', 'ok', cv >= share_cv),
      jsonb_build_object('label', 'Calls', 'value', calls || case when untagged > 0 then ' · ' || untagged || ' untagged' else '' end, 'ok', untagged = 0));
    if untagged > 0 and not ('call_tagging' = any(used_today)) then
      actions := actions || jsonb_build_object('text', 'Tag today''s ' || untagged || case when untagged = 1 then ' call' else ' calls' end || ' so BD and client calls count', 'prompt', '/tagcalls', 'tool', 'call_tagging');
    end if;
    if jsonb_array_length(coalesce(dd->'prep', '[]')) > 0 then
      actions := actions || jsonb_build_object('text', jsonb_array_length(dd->'prep') || case when jsonb_array_length(dd->'prep') = 1 then ' interview' else ' interviews' end
        || ' next working day: prep the candidate', 'prompt', '/interviewprep', 'tool', 'candidate_profile');
    end if;
    if jsonb_array_length(coalesce(dd->'feedback_due', '[]')) > 0 and not ('awaiting_feedback_report' = any(used_today)) then
      actions := actions || jsonb_build_object('text', 'Log feedback on ' || jsonb_array_length(dd->'feedback_due') || ' interviewed', 'prompt', '/feedback', 'tool', 'awaiting_feedback_report');
    end if;
    select (public.placements_with_fees(date_trunc('quarter', today)::date, today + 1, me.name, 14)->'totals'->>'overdue_no_won_deal')::int into overdue;
    if coalesce(overdue, 0) > 0 then
      actions := actions || jsonb_build_object('text', overdue || case when overdue = 1 then ' placement has' else ' placements have' end || ' no Won deal after 14 days, so it isn''t billed', 'prompt', '/won', 'tool', 'update_deal');
    end if;
    if dow = 5 then
      stats := stats || jsonb_build_array(
        jsonb_build_object('label', 'This week: CVs', 'value', coalesce(wk->'cv_sent'->>'actual', '0') || ' of ' || round(p_cv), 'ok', coalesce((wk->'cv_sent'->>'actual')::numeric, 0) >= p_cv),
        jsonb_build_object('label', 'This week: interviews', 'value', coalesce(wk->'first_interview'->>'actual', '0') || ' of ' || round(p_iv), 'ok', coalesce((wk->'first_interview'->>'actual')::numeric, 0) >= p_iv));
      if exists (select 1 from jsonb_array_elements(q->'items') i where i->>'kind' = 'pushtell') and not ('push_tell' = any(used_today)) then
        actions := actions || jsonb_build_object('text', 'Push & Tell still to do for your A and B grade clients', 'prompt', '/pushtell', 'tool', 'push_tell');
      end if;
    end if;
    headline := case when dow = 5 then 'Your week, ' || me.first_name else 'Before you finish, ' || me.first_name end;
    quiet := jsonb_array_length(actions) = 0;

  elsif p_slot = 'monday' then
    select x into bill from jsonb_array_elements(public.billing_report()->'consultants') x where x->>'name' = me.name limit 1;
    weeks_in := greatest(1, ((today - date_trunc('quarter', today)::date) / 7) + 1);
    exp_bill := coalesce((bill->>'quarterly_target')::numeric, 0) * weeks_in / 13;
    stats := jsonb_build_array(
      jsonb_build_object('label', 'Plan this week', 'value', round(p_cv) || ' CVs · ' || round(p_ir) || ' req · ' || round(p_iv) || ' 1st', 'ok', true),
      jsonb_build_object('label', 'Billing this quarter', 'value',
        case when bill->>'quarterly_target' is null then '£' || to_char(coalesce((bill->>'won_qtr')::numeric, 0), 'FM999,999,999') || ' Won (no target set)'
             else '£' || to_char(coalesce((bill->>'won_qtr')::numeric, 0), 'FM999,999,999') || ' of £' || to_char((bill->>'quarterly_target')::numeric, 'FM999,999,999') end,
        'ok', bill->>'quarterly_target' is null or coalesce((bill->>'won_qtr')::numeric, 0) >= exp_bill),
      jsonb_build_object('label', 'Pipeline', 'value', '£' || to_char(coalesce((bill->>'pipeline_open')::numeric, 0), 'FM999,999,999') || ' in play', 'ok', true));
    vz := (select c from jsonb_array_elements(public.client_visits(p_consultant)->'consultants') c limit 1);
    if vz is not null and jsonb_array_length(coalesce(vz->'visits', '[]')) < 2 then
      actions := actions || jsonb_build_object('text', 'Client visits: ' || jsonb_array_length(coalesce(vz->'visits', '[]')) || ' of 2 this quarter'
        || coalesce('. ' || (vz->'suggestions'->0->>'client') || ' is a good one to ask', ''), 'prompt', '/visitplan', 'tool', 'client_visits');
    end if;
    if bill->>'quarterly_target' is not null and coalesce((bill->>'won_qtr')::numeric, 0) < exp_bill then
      actions := actions || jsonb_build_object('text', 'Billing is behind the pace for week ' || weeks_in || ' of 13: chase the offers in play first', 'prompt', '/billing', 'tool', 'billing');
    end if;
    headline := 'Your week ahead, ' || me.first_name;
  else
    return jsonb_build_object('skip', true, 'reason', 'unknown slot');
  end if;

  select array_agg(a->>'tool') into suggested from (select a from jsonb_array_elements(actions) a limit 3) s;
  suggested := coalesce(suggested, '{}');

  -- Command of the week: the first one they haven't used in 28 days and isn't already suggested above.
  select jsonb_build_object('command', c.cmd, 'why', c.why, 'tool', c.tool) into tip
    from (values (1, '/intake', 'writes up your last candidate call from the Devyce summary', 'call_notes'),
                 (2, '/tagcalls', 'tags a day of calls in a minute, so BD and client calls count', 'call_tagging'),
                 (3, '/visitplan', 'picks which clients to visit this quarter and drafts the request', 'client_visits'),
                 (4, 'prep my queue', 'drafts the admin for every call on your 08:30 list', 'action_queue'),
                 (5, '/boolean', 'builds a LinkedIn or job board search for a role', 'content:boolean'),
                 (6, '/specpitch', 'writes an anonymised pitch of a strong candidate to a client', 'content:spec_pitch'),
                 (7, '/pushtell', 'drafts the weekly update for your A and B grade clients', 'push_tell')) c(ord, cmd, why, tool)
    where not (c.tool = any(used_28)) and not (c.tool = any(suggested)) order by c.ord limit 1;
  return jsonb_build_object('skip', false, 'consultant', me.name, 'first_name', me.first_name, 'slot', p_slot, 'headline', headline,
    'quiet', quiet, 'stats', stats, 'actions', (select coalesce(jsonb_agg(a), '[]'::jsonb) from (select a from jsonb_array_elements(actions) a limit 3) s),
    'tip', case when p_slot = 'midday' then tip end, 'suggested', to_jsonb(suggested),
    'early_week', dow <= 2);
end;
$function$;
revoke execute on function public.coach_nudges(bigint, text) from public, anon, authenticated;
grant execute on function public.coach_nudges(bigint, text) to service_role;

-- Same pattern as action_queue_if_due: scheduled at two UTC hours, sends once at the London hour.
create or replace function public.coach_if_due(p_slot text, p_london_hour integer)
returns void language plpgsql security definer set search_path to 'public'
as $function$
declare hdrs jsonb;
begin
  if extract(hour from (now() at time zone 'Europe/London'))::int <> p_london_hour then
    return;
  end if;
  select jsonb_build_object('Authorization', 'Bearer ' || value, 'Content-Type', 'application/json')
    into hdrs from app_settings where key = 'cron_bearer';
  if hdrs is null then
    raise warning 'coach_if_due: app_settings.cron_bearer not set, coach skipped';
    return;
  end if;
  perform net.http_post(
    url := 'https://kzcmssldvtjnbwwunuwm.supabase.co/functions/v1/coach-dm',
    headers := hdrs, body := jsonb_build_object('slot', p_slot), timeout_milliseconds := 55000);
end;
$function$;
revoke execute on function public.coach_if_due(text, integer) from public, anon, authenticated;

select cron.schedule('coach-midday', '30 11,12 * * 1-5', $$select public.coach_if_due('midday', 12);$$);
select cron.schedule('coach-wrap', '45 15,16 * * 1-5', $$select public.coach_if_due('wrap', 16);$$);
select cron.schedule('coach-monday', '45 7,8 * * 1', $$select public.coach_if_due('monday', 8);$$);
insert into cron_manifest (jobname, schedule, note, required) values
  ('coach-midday', '30 11,12 * * 1-5', 'coach midday DM, 12:30 UK', true),
  ('coach-wrap', '45 15,16 * * 1-5', 'coach wrap-up DM, 16:45 UK', true),
  ('coach-monday', '45 7,8 * * 1', 'coach week-ahead DM, Mondays 08:45 UK', true)
on conflict (jobname) do update set schedule = excluded.schedule, note = excluded.note, required = excluded.required;
