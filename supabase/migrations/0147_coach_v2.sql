-- 0147_coach_v2.sql
-- The coach, second pass (04/11/2026), from a week of shadow messages: 56% suggested /match and 35%
-- /feedback, mostly the same thing every day, as commands to run rather than people to call.
--
-- 1. No repeats: a kind of suggestion made to someone on their last coached day is skipped today, so
--    the others come forward (for feedback and booking, only the same candidate is skipped). Offers,
--    interview prep and the call-tagging list are exempt (each is a different, time-bound thing).
-- 2. Named: each suggestion says who and what (the candidate, job, client, interview, lapsed client),
--    from the same data as the 08:30 queue and the diary.
-- 3. Buttons: every suggestion has Done and Snooze to tomorrow; the 16:45 message lists today's
--    untagged client-contact calls with a suggested category and one button to tag them as shown.
-- 4. Measured: coach_log keeps what each message suggested; coach_feedback the presses; and
--    coach_effect() says how often each kind was acted on within 3 hours.
-- 5. Ahead of pace: one line, no stats, when someone is ahead for the week with nothing urgent.

alter table public.coach_log add column if not exists actions jsonb not null default '[]'::jsonb;
alter table public.coach_log add column if not exists channel text;
alter table public.coach_log add column if not exists message_ts text;

create table if not exists public.coach_feedback (
  id bigint generated always as identity primary key,
  coach_log_id bigint not null references public.coach_log(id) on delete cascade,
  action_idx int not null,
  consultant_recruitcrm_id bigint not null,
  action_key text,
  response text not null check (response in ('done', 'snooze', 'tagged')),
  detail jsonb,
  created_at timestamptz not null default now()
);
create index if not exists coach_feedback_log_idx on public.coach_feedback (coach_log_id);
alter table public.coach_feedback enable row level security;
revoke all on table public.coach_feedback from anon, authenticated;

-- A suggestion someone has dealt with or put off: skipped until the date has passed.
create table if not exists public.coach_snooze (
  consultant_recruitcrm_id bigint not null,
  action_key text not null,
  until date not null,
  created_at timestamptz not null default now(),
  primary key (consultant_recruitcrm_id, action_key)
);
alter table public.coach_snooze enable row level security;
revoke all on table public.coach_snooze from anon, authenticated;

create or replace function public.coach_nudges(p_consultant bigint, p_slot text)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare
  me record; plan jsonb; wk jsonb; q jsonb; dd jsonb; bill jsonb; vz jsonb; lp jsonb;
  dow int := extract(isodow from (now() at time zone 'Europe/London'))::int;
  today date := (now() at time zone 'Europe/London')::date;
  cv int; ir int; iv int; calls int; untagged int; done_today int; open_items int;
  p_cv numeric; p_ir numeric; p_iv numeric; share_cv int; share_ir int; share_iv int;
  wk_cv int; pace_cv int; ahead boolean := false;
  used_today text[]; used_28 text[]; prev_kinds text[]; prev_keys text[]; snoozed text[];
  cand jsonb := '[]'::jsonb; actions jsonb; suggested text[] := '{}'; stats jsonb; tip jsonb; headline text;
  quiet boolean := false; short text;
  it jsonb; n int; overdue int; weeks_in int; exp_bill numeric; tagcalls jsonb;
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
  wk_cv := coalesce((wk->'cv_sent'->>'actual')::int, 0);
  -- Pace for the week so far: by midday, half of today counts; by the wrap, all of it.
  pace_cv := ceil(p_cv * (least(dow, 5) - case when p_slot = 'midday' then 0.5 else 0 end) / 5.0);
  ahead := dow between 2 and 5 and wk_cv > 0 and wk_cv >= pace_cv;

  select count(distinct e.candidate_slug||'|'||e.job_slug) filter (where e.stage_metric = 'cv_sent'),
         count(distinct e.candidate_slug||'|'||e.job_slug) filter (where e.stage_metric = 'interview_request'),
         count(distinct e.candidate_slug||'|'||e.job_slug) filter (where e.stage_metric = 'first_interview')
    into cv, ir, iv from candidate_stage_events e where e.consultant = me.name and e.event_date = today;
  select count(*) into calls from call_activity where consultant_recruitcrm_id = p_consultant and call_started_on >= today and call_started_on < today + 1;
  -- Only calls to client contacts count toward a target, so those are the ones worth tagging.
  select count(*) into untagged from call_activity
    where consultant_recruitcrm_id = p_consultant and custom_call_type is null and related_to_type = 'contact'
      and duration_seconds >= 30 and (call_started_on at time zone 'Europe/London')::date = today;

  q := public.action_queue(p_consultant);
  select count(*) into done_today from action_queue_done where consultant_recruitcrm_id = p_consultant and done_at >= today::timestamptz;
  select count(*) into open_items from jsonb_array_elements(q->'items') i
    where i->>'kind' not in ('plan', 'cleanup', 'meetings', 'client_visits', 'pushtell');
  select array_agg(distinct tool) into used_today from mcp_call_log where consultant_recruitcrm_id = p_consultant and created_at >= today::timestamptz;
  select array_agg(distinct tool) into used_28 from mcp_call_log where consultant_recruitcrm_id = p_consultant and created_at >= now() - interval '28 days';
  used_today := coalesce(used_today, '{}'); used_28 := coalesce(used_28, '{}');
  select x into dd from jsonb_array_elements(public.diary_digest()->'by_consultant') x where x->>'consultant' = me.name limit 1;

  -- What this person was told on their last coached day (any slot). Rows from before 0147 only have
  -- the tools, so map those to kinds.
  select coalesce(array_agg(distinct k), '{}') into prev_kinds from (
    select x->>'kind' k from coach_log l, jsonb_array_elements(l.actions) x
      where l.consultant_recruitcrm_id = p_consultant
        and (l.sent_at at time zone 'Europe/London')::date = (select max((sent_at at time zone 'Europe/London')::date) from coach_log
              where consultant_recruitcrm_id = p_consultant and (sent_at at time zone 'Europe/London')::date < today)
    union
    select case t when 'match_candidates' then 'match' when 'awaiting_feedback_report' then 'feedback'
                  when 'interview_requests_unbooked' then 'unbooked' when 'call_tagging' then 'tag_midday'
                  when 'bd_report' then 'bd' when 'client_visits' then 'visits' when 'push_tell' then 'pushtell'
                  when 'billing' then 'billing' end
      from coach_log l, unnest(l.suggested) t
      where l.consultant_recruitcrm_id = p_consultant and l.actions = '[]'::jsonb
        and (l.sent_at at time zone 'Europe/London')::date = (select max((sent_at at time zone 'Europe/London')::date) from coach_log
              where consultant_recruitcrm_id = p_consultant and (sent_at at time zone 'Europe/London')::date < today)) s
  where k is not null;
  select coalesce(array_agg(distinct x->>'key'), '{}') into prev_keys from coach_log l, jsonb_array_elements(l.actions) x
    where l.consultant_recruitcrm_id = p_consultant
      and (l.sent_at at time zone 'Europe/London')::date = (select max((sent_at at time zone 'Europe/London')::date) from coach_log
            where consultant_recruitcrm_id = p_consultant and (sent_at at time zone 'Europe/London')::date < today);
  select coalesce(array_agg(action_key), '{}') into snoozed from coach_snooze where consultant_recruitcrm_id = p_consultant and until >= today;

  if p_slot = 'midday' then
    stats := jsonb_build_array(
      jsonb_build_object('label', 'CVs sent', 'value', cv || ' of ' || share_cv, 'ok', cv >= share_cv),
      jsonb_build_object('label', 'Interview requests', 'value', ir || ' of ' || share_ir, 'ok', ir >= share_ir),
      jsonb_build_object('label', 'Queue', 'value', done_today || ' done, ' || open_items || ' open', 'ok', open_items = 0),
      jsonb_build_object('label', 'Calls', 'value', calls || case when untagged > 0 then ' · ' || untagged || ' to clients untagged' else '' end, 'ok', untagged = 0));
    for it in select i from jsonb_array_elements(q->'items') i where i->>'kind' = 'offer' limit 1 loop
      cand := cand || jsonb_build_object('kind', 'offer', 'key', it->>'item_key', 'tool', 'action_queue', 'prompt', 'prep my queue',
        'candidate_slug', it->>'candidate_slug', 'job_slug', it->>'job_slug',
        'text', split_part(it->>'action', ':', 1) || ' on ' || coalesce(it->>'who', 'the candidate') || ' for ' || coalesce(it->>'job', 'the role')
          || coalesce(':' || nullif(substr(it->>'action', strpos(it->>'action', ':') + 1), ''), ''));
    end loop;
    if cv < share_cv then
      select i into it from jsonb_array_elements(q->'items') i where i->>'kind' = 'cold_job' limit 1;
      cand := cand || jsonb_build_object('kind', 'match', 'key', 'match:' || coalesce(it->>'job', '-'), 'tool', 'match_candidates',
        'prompt', '/match ' || coalesce(it->>'job', 'my coldest role'),
        'text', (share_cv - cv) || case when share_cv - cv = 1 then ' more CV keeps' else ' more CVs keep' end || ' you on plan today'
          || coalesce(': start with ' || (it->>'job') || coalesce(' at ' || (it->>'client'), ''), ''));
    end if;
    if not ('interview_requests_unbooked' = any(used_today)) then
      select count(*) into n from jsonb_array_elements(q->'items') i where i->>'kind' = 'unbooked';
      for it in select i from jsonb_array_elements(q->'items') i where i->>'kind' = 'unbooked' limit 1 loop
        cand := cand || jsonb_build_object('kind', 'unbooked', 'key', it->>'item_key', 'tool', 'interview_requests_unbooked', 'prompt', '/unbooked',
          'candidate_slug', it->>'candidate_slug', 'job_slug', it->>'job_slug',
          'text', 'Book ' || coalesce(it->>'who', 'the candidate') || '''s interview for ' || coalesce(it->>'job', 'the role')
            || coalesce(' at ' || (it->>'client'), '') || ' (' || lower(left(it->>'action', 1)) || substr(split_part(it->>'action', ':', 1), 2) || ')'
            || case when n > 1 then ', and ' || (n - 1) || ' more waiting' else '' end);
      end loop;
    end if;
    if jsonb_array_length(coalesce(dd->'feedback_due', '[]')) > 0 and not ('awaiting_feedback_report' = any(used_today)) then
      it := dd->'feedback_due'->0; n := jsonb_array_length(dd->'feedback_due');
      cand := cand || jsonb_build_object('kind', 'feedback', 'key', 'feedback:' || (it->>'meeting_id'), 'tool', 'awaiting_feedback_report', 'prompt', '/feedback',
        'candidate_slug', it->>'candidate_slug', 'job_slug', it->>'job_slug',
        'text', 'Get feedback on ' || coalesce(it->>'candidate', 'the candidate') || ' for ' || coalesce(it->>'job', 'the role')
          || coalesce(' at ' || (it->>'client'), '') || ': interviewed ' || coalesce(it->>'held', 'recently') || ', nothing logged since'
          || case when n > 1 then ', and ' || (n - 1) || ' more' else '' end);
    end if;
    select count(*) into n from jsonb_array_elements(q->'items') i where i->>'kind' = 'cv_chase';
    for it in select i from jsonb_array_elements(q->'items') i where i->>'kind' = 'cv_chase' limit 1 loop
      cand := cand || jsonb_build_object('kind', 'cv_chase', 'key', it->>'item_key', 'tool', 'action_queue', 'prompt', 'prep my queue',
        'candidate_slug', it->>'candidate_slug', 'job_slug', it->>'job_slug',
        'text', 'Chase the client on ' || coalesce(it->>'who', 'the candidate') || ' for ' || coalesce(it->>'job', 'the role')
          || ' (' || split_part(it->>'action', ':', 1) || ')' || case when n > 1 then ', and ' || (n - 1) || ' more CVs with no response' else '' end);
    end loop;
    if exists (select 1 from jsonb_array_elements(q->'items') i where i->>'kind' = 'bd') then
      -- A named former client to ring, not yet suggested to this person in the last 14 days.
      select c into lp from jsonb_array_elements(public.lapsed_clients(6, me.name, 50)->'clients') c
        where not ('lapsed:' || (c->>'company_slug') = any(snoozed))
          and not exists (select 1 from coach_log l, jsonb_array_elements(l.actions) x
                          where l.consultant_recruitcrm_id = p_consultant and l.sent_at >= now() - interval '14 days'
                            and x->>'key' = 'lapsed:' || (c->>'company_slug'))
        limit 1;
      if lp is not null then
        cand := cand || jsonb_build_object('kind', 'bd', 'key', 'lapsed:' || (lp->>'company_slug'), 'tool', 'lapsed_clients',
          'prompt', '/lapsed ' || (lp->>'client'), 'company_slug', lp->>'company_slug',
          'text', 'Behind on BD calls: ring ' || (lp->>'client') || ', ' || coalesce(lp->>'placements', '0') || ' placements with us and no job since '
            || to_char((lp->>'last_job')::date, 'MM/YYYY'));
      else
        cand := cand || jsonb_build_object('kind', 'bd', 'key', 'bd:' || today, 'tool', 'bd_report', 'prompt', '/bd',
          'text', 'Behind on BD calls this week: a short target list and a spec pitch');
      end if;
    end if;
    if untagged >= 3 and not ('call_tagging' = any(used_today)) then
      cand := cand || jsonb_build_object('kind', 'tag_midday', 'key', 'tag_midday:' || today, 'tool', 'call_tagging', 'prompt', '/tagcalls',
        'text', untagged || ' calls to clients untagged so far. The 16:45 message tags them in one press');
    end if;

  elsif p_slot = 'wrap' then
    stats := jsonb_build_array(
      jsonb_build_object('label', 'Today', 'value', cv || ' CV · ' || ir || ' req · ' || iv || ' 1st', 'ok', cv >= share_cv),
      jsonb_build_object('label', 'Calls', 'value', calls || case when untagged > 0 then ' · ' || untagged || ' to clients untagged' else '' end, 'ok', untagged = 0));
    -- Today's untagged client-contact calls, each with a suggested category: how that contact's calls
    -- were tagged before, else the company's status, else a job in the last 18 months (client) or not (BD).
    -- The message shows every one; nothing is written until the recruiter presses the button.
    with c as (
      select a.recruitcrm_id id, a.call_started_on, a.duration_seconds, a.related_to slug
        from call_activity a
       where a.consultant_recruitcrm_id = p_consultant and a.custom_call_type is null and a.related_to_type = 'contact'
         and a.duration_seconds >= 30 and (a.call_started_on at time zone 'Europe/London')::date = today
       order by a.call_started_on limit 8),
    s as (
      select c.*, ct.name who, cl.company_name company, cl.company_status st,
        (select p.custom_call_type from call_activity p where p.related_to = c.slug and p.custom_call_type is not null
           and p.custom_call_type !~* 'voicemail' group by 1 order by count(*) desc limit 1) prior,
        exists (select 1 from jobs j where j.company_slug = ct.company_slug and j.created_date >= now() - interval '18 months') has_job
      from c left join contacts ct on ct.slug = c.slug
             left join clients cl on cl.company_slug = ct.company_slug and cl.deleted_at is null)
    select coalesce(jsonb_agg(jsonb_build_object(
        'id', id, 'at', to_char(call_started_on at time zone 'Europe/London', 'HH24:MI'), 'minutes', round(duration_seconds / 60.0, 1),
        'with', who, 'company', company,
        'type', case when prior is not null then prior when st ~* '^client$' then 'Contact - Client'
                     when st ~* 'prospect|engaged|passive' then 'Contact - Prospect (BD)'
                     when has_job then 'Contact - Client' else 'Contact - Prospect (BD)' end,
        'why', case when prior is not null then 'tagged that way before' when st ~* '^client$' then 'company is a Client'
                    when st ~* 'prospect|engaged|passive' then 'company is ' || st
                    when has_job then 'a job there in the last 18 months' else 'no job there in 18 months' end)
        order by call_started_on), '[]'::jsonb)
      into tagcalls from s;
    if jsonb_array_length(tagcalls) > 0 then
      cand := cand || jsonb_build_object('kind', 'tag_calls', 'key', 'tag:' || today, 'tool', 'call_tagging', 'prompt', '/tagcalls',
        'calls', tagcalls,
        'text', 'Tag today''s ' || jsonb_array_length(tagcalls) || case when jsonb_array_length(tagcalls) = 1 then ' call' else ' calls' end
          || ' to clients so BD and client calls count');
    end if;
    if jsonb_array_length(coalesce(dd->'prep', '[]')) > 0 then
      it := dd->'prep'->0; n := jsonb_array_length(dd->'prep');
      cand := cand || jsonb_build_object('kind', 'prep', 'key', 'prep:' || (it->>'meeting_id'), 'tool', 'candidate_profile',
        'prompt', '/interviewprep ' || coalesce(it->>'candidate', ''), 'candidate_slug', it->>'candidate_slug', 'job_slug', it->>'job_slug',
        'text', 'Prep ' || coalesce(it->>'candidate', 'the candidate') || ' for ' || coalesce(it->>'job', 'the interview')
          || coalesce(' at ' || (it->>'client'), '') || coalesce(', ' || (it->>'time'), '') || ' next working day'
          || case when n > 1 then ', and ' || (n - 1) || ' more' else '' end);
    end if;
    if jsonb_array_length(coalesce(dd->'feedback_due', '[]')) > 0 and not ('awaiting_feedback_report' = any(used_today)) then
      it := dd->'feedback_due'->0; n := jsonb_array_length(dd->'feedback_due');
      cand := cand || jsonb_build_object('kind', 'feedback', 'key', 'feedback:' || (it->>'meeting_id'), 'tool', 'awaiting_feedback_report', 'prompt', '/feedback',
        'candidate_slug', it->>'candidate_slug', 'job_slug', it->>'job_slug',
        'text', 'Log feedback on ' || coalesce(it->>'candidate', 'the candidate') || ' for ' || coalesce(it->>'job', 'the role')
          || coalesce(' at ' || (it->>'client'), '') || case when n > 1 then ', and ' || (n - 1) || ' more' else '' end);
    end if;
    select (public.placements_with_fees(date_trunc('quarter', today)::date, today + 1, me.name, 14)->'totals'->>'overdue_no_won_deal')::int into overdue;
    if coalesce(overdue, 0) > 0 then
      cand := cand || jsonb_build_object('kind', 'won_overdue', 'key', 'won_overdue:' || today, 'tool', 'update_deal', 'prompt', '/won',
        'text', overdue || case when overdue = 1 then ' placement has' else ' placements have' end || ' no Won deal after 14 days, so it isn''t billed');
    end if;
    if dow = 5 then
      stats := stats || jsonb_build_array(
        jsonb_build_object('label', 'This week: CVs', 'value', wk_cv || ' of ' || round(p_cv), 'ok', wk_cv >= p_cv),
        jsonb_build_object('label', 'This week: interviews', 'value', coalesce(wk->'first_interview'->>'actual', '0') || ' of ' || round(p_iv), 'ok', coalesce((wk->'first_interview'->>'actual')::numeric, 0) >= p_iv));
      if exists (select 1 from jsonb_array_elements(q->'items') i where i->>'kind' = 'pushtell') and not ('push_tell' = any(used_today)) then
        cand := cand || jsonb_build_object('kind', 'pushtell', 'key', 'pushtell:' || today, 'tool', 'push_tell', 'prompt', '/pushtell',
          'text', 'Push & Tell still to do for your A and B grade clients');
      end if;
    end if;

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
      cand := cand || jsonb_build_object('kind', 'visits', 'key', 'visits:' || today, 'tool', 'client_visits', 'prompt', '/visitplan',
        'text', 'Client visits: ' || jsonb_array_length(coalesce(vz->'visits', '[]')) || ' of 2 this quarter'
          || coalesce('. Ask ' || (vz->'suggestions'->0->>'client') || ' for a visit', ''));
    end if;
    if bill->>'quarterly_target' is not null and coalesce((bill->>'won_qtr')::numeric, 0) < exp_bill then
      cand := cand || jsonb_build_object('kind', 'billing', 'key', 'billing:' || today, 'tool', 'billing', 'prompt', '/billing',
        'text', 'Billing is behind the pace for week ' || weeks_in || ' of 13: chase the offers in play first');
    end if;
  else
    return jsonb_build_object('skip', true, 'reason', 'unknown slot');
  end if;

  -- Drop what was snoozed or marked done, then anything that repeats their last coached day: the same
  -- kind for the general nudges (match, chase, BD and so on), the same person for feedback and booking
  -- (a different candidate is news). Offers, interview prep and call tagging are new every day.
  select coalesce(jsonb_agg(a order by ord), '[]'::jsonb) into actions from (
    select a, ord from jsonb_array_elements(cand) with ordinality t(a, ord)
     where not (a->>'key' = any(snoozed))
       and (a->>'kind' in ('offer', 'prep', 'tag_calls')
            or (a->>'kind' in ('feedback', 'unbooked') and not (a->>'key' = any(prev_keys)))
            or (a->>'kind' not in ('feedback', 'unbooked') and not (a->>'kind' = any(prev_kinds))))
     order by ord limit 3) s;
  select coalesce(array_agg(a->>'tool'), '{}') into suggested from jsonb_array_elements(actions) a;

  if p_slot = 'midday' then
    headline := case when dow <= 2 then 'Your midday check, ' || me.first_name || '. Early in the week'
                     when ahead then 'Your midday check, ' || me.first_name || '. Ahead of the week'
                     when cv >= share_cv and open_items = 0 then 'Your midday check, ' || me.first_name || '. On plan'
                     else 'Your midday check, ' || me.first_name end;
    -- Ahead with nothing urgent, or on plan with nothing to do: one line, no stats.
    if ahead and not exists (select 1 from jsonb_array_elements(actions) a where a->>'kind' in ('offer', 'unbooked', 'feedback')) then
      short := wk_cv || ' CVs sent this week, ahead of the pace for ' || to_char(today, 'FMDay') || '. Nothing urgent, so keep going.';
      actions := '[]'::jsonb; suggested := '{}';
    elsif cv >= share_cv and ir >= share_ir and open_items = 0 and jsonb_array_length(actions) = 0 then
      short := 'On plan and your queue is clear. Good morning''s work.';
    end if;
    quiet := short is not null;
  elsif p_slot = 'wrap' then
    headline := case when dow = 5 then 'Your week, ' || me.first_name else 'Before you finish, ' || me.first_name end;
    quiet := jsonb_array_length(actions) = 0;
  else
    headline := 'Your week ahead, ' || me.first_name;
  end if;

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
    'quiet', quiet, 'short', short, 'stats', stats, 'actions', actions,
    'tip', case when p_slot = 'midday' and short is null then tip end, 'suggested', to_jsonb(suggested),
    'early_week', dow <= 2, 'ahead', ahead);
end;
$function$;
revoke execute on function public.coach_nudges(bigint, text) from public, anon, authenticated;
grant execute on function public.coach_nudges(bigint, text) to service_role;

-- How often each kind of suggestion was acted on within 3 hours of the message: a Done or tag press,
-- the suggested tool used, or, for a named suggestion, a call to that candidate or company or a stage
-- move on that candidate. In shadow mode recruiters never saw the message, so those rows are the
-- baseline: how often it would have happened anyway.
create or replace function public.coach_effect(p_days int default 28)
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  with a as (
    select l.id, l.consultant_recruitcrm_id cid, l.sent_at, l.shadow, l.slot, x.ord::int - 1 idx, x.a
      from coach_log l cross join lateral jsonb_array_elements(l.actions) with ordinality x(a, ord)
     where l.sent_at >= now() - make_interval(days => p_days)),
  o as (
    select a.*,
      exists (select 1 from coach_feedback f where f.coach_log_id = a.id and f.action_idx = a.idx and f.response in ('done', 'tagged')) pressed_done,
      exists (select 1 from coach_feedback f where f.coach_log_id = a.id and f.action_idx = a.idx and f.response = 'snooze') pressed_snooze,
      (exists (select 1 from mcp_call_log m where m.consultant_recruitcrm_id = a.cid and m.ok and m.tool = a.a->>'tool'
                 and m.created_at >= a.sent_at and m.created_at < a.sent_at + interval '3 hours')
       or (a.a ? 'candidate_slug' and (
             exists (select 1 from call_activity c where c.consultant_recruitcrm_id = a.cid and c.related_to = a.a->>'candidate_slug'
                       and c.call_started_on >= a.sent_at and c.call_started_on < a.sent_at + interval '3 hours')
          or exists (select 1 from candidate_stage_events e where e.consultant_id = a.cid and e.candidate_slug = a.a->>'candidate_slug'
                       and e.event_timestamp >= (a.sent_at at time zone 'UTC') and e.event_timestamp < (a.sent_at at time zone 'UTC') + interval '3 hours')))
       or (a.a ? 'company_slug' and exists (select 1 from call_activity c join contacts ct on ct.slug = c.related_to
                       where c.consultant_recruitcrm_id = a.cid and ct.company_slug = a.a->>'company_slug'
                         and c.call_started_on >= a.sent_at and c.call_started_on < a.sent_at + interval '3 hours'))
       or (a.a->>'kind' = 'match' and exists (select 1 from candidate_stage_events e where e.consultant_id = a.cid and e.stage_metric = 'cv_sent'
                       and e.event_timestamp >= (a.sent_at at time zone 'UTC') and e.event_timestamp < (a.sent_at at time zone 'UTC') + interval '3 hours'))
       or (a.a->>'kind' in ('tag_calls', 'tag_midday') and exists (select 1 from audit_log g where g.actor = a.cid::text and g.action = 'set_call_type'
                       and g.created_at >= a.sent_at and g.created_at < a.sent_at + interval '3 hours'))
      ) acted_signal
    from a)
  select jsonb_build_object(
    'window_days', p_days,
    'definition', 'Each suggestion in a coach message, and whether it was acted on within 3 hours: Done or a tag press, the suggested tool used, or for a named suggestion a call to that candidate or company or a stage move on that candidate. Shadow rows were never seen by the recruiter, so they are the baseline. Acted on is a signal, not proof: some of it would have happened anyway.',
    'by_kind', (select coalesce(jsonb_agg(jsonb_build_object('kind', kind, 'mode', mode, 'suggested', n, 'acted_3h', acted,
                  'acted_pct', round(100.0 * acted / nullif(n, 0), 1), 'done', done, 'snoozed', snoozed) order by mode, n desc), '[]'::jsonb)
                from (select a->>'kind' kind, case when shadow then 'shadow' else 'live' end mode, count(*) n,
                             count(*) filter (where pressed_done or acted_signal) acted,
                             count(*) filter (where pressed_done) done, count(*) filter (where pressed_snooze) snoozed
                        from o group by 1, 2) k),
    'by_person', (select coalesce(jsonb_agg(jsonb_build_object('consultant', c.name, 'mode', mode, 'suggested', n, 'acted_3h', acted,
                  'acted_pct', round(100.0 * acted / nullif(n, 0), 1)) order by c.name), '[]'::jsonb)
                from (select cid, case when shadow then 'shadow' else 'live' end mode, count(*) n,
                             count(*) filter (where pressed_done or acted_signal) acted from o group by 1, 2) p
                join consultants c on c.recruitcrm_id = p.cid));
$function$;
revoke execute on function public.coach_effect(int) from public, anon, authenticated;
grant execute on function public.coach_effect(int) to service_role;
