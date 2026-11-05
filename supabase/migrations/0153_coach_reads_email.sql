-- 0153_coach_reads_email.sql
-- 05/11/2026 (#troubleshooting 1793816870.805809): the coach reads each consultant's own connected
-- Outlook inbox, so a nudge can be an email waiting on a reply. Rule-based, no AI (13/10/2026 rule):
--   unread for 2+ hours, received in the last 3 days, category 'never' (offer, pay, fees, legal,
--   complaint), 'other' (no rule matched) or routine scheduling. Automated, acknowledgement and admin
--   mail are left out. The oldest 'never' email first, then the oldest of the rest.
--   midday: a 'never' email sits right after offers; any other after the CV chase.
--   wrap:   after call tagging.
--   Like feedback and booking, the same email is not repeated on the next coached day, but a new one
--   is news. Snooze works per email. Skipped once they have used inbox or draft_reply today.
-- Limits: only consultants with a mailbox connected (2 today); "unread" stands in for "not replied",
-- since sent mail is not read, so an email read and left unanswered is missed.
-- The rest of coach_nudges() is 0148's, except the prep-my-queue tip no longer names the 08:30 DM
-- (retired in 0150).

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
  it jsonb; n int; overdue int; weeks_in int; exp_bill numeric; tagcalls jsonb; offers jsonb; lw jsonb;
  bd_a int; cc_a int; bd_l int; cc_l int;
  em record; n_em int := 0; em_item jsonb;
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
  -- 0148: RecruitCRM's diary holds no leave, so besides the Away until date (coach_pause), skip the
  -- midday and wrap messages when nothing at all is logged today: no call, no stage move, no queue
  -- item done, no Octagon use. That is leave, sickness or a day out, not a day to nudge.
  if p_slot in ('midday', 'wrap') and calls = 0 and coalesce(cv, 0) + coalesce(ir, 0) + coalesce(iv, 0) = 0
     and done_today = 0 and cardinality(used_today) = 0 then
    return jsonb_build_object('skip', true, 'reason', 'no activity today');
  end if;
  bd_a := coalesce((wk->'bd_calls'->>'actual')::int, 0); cc_a := coalesce((wk->'client_calls'->>'actual')::int, 0);
  bd_l := coalesce((wk->'bd_calls'->>'likely_untagged')::int, 0); cc_l := coalesce((wk->'client_calls'->>'likely_untagged')::int, 0);

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

  -- 0153: email waiting on them, from their own connected Outlook inbox (inbox-sync keeps is_read
  -- current). Unread for 2 hours or more, in the last 3 days, and of a kind that needs a reply:
  -- 'never' (offer, pay, fees, legal, complaint: always a personal reply), 'other' (no rule matched)
  -- and scheduling. Automated mail, acknowledgements and admin are left out. Nothing if they have no
  -- mailbox connected, or they already worked the inbox today.
  if exists (select 1 from inbox_mailboxes where consultant_recruitcrm_id = p_consultant and enabled)
     and not ('inbox' = any(used_today)) and not ('draft_reply' = any(used_today)) then
    select count(*) into n_em from inbox_messages m
     where m.consultant_recruitcrm_id = p_consultant and m.is_read = false
       and (m.category in ('never', 'other') or (m.category = 'routine' and m.reason = 'scheduling'))
       and m.received_at >= now() - interval '3 days' and m.received_at < now() - interval '2 hours';
    select m.* into em from inbox_messages m
     where m.consultant_recruitcrm_id = p_consultant and m.is_read = false
       and (m.category in ('never', 'other') or (m.category = 'routine' and m.reason = 'scheduling'))
       and m.received_at >= now() - interval '3 days' and m.received_at < now() - interval '2 hours'
       and not ('email:' || m.id = any(snoozed))
     order by (m.category = 'never') desc, m.received_at
     limit 1;
    if em.id is not null then
      em_item := jsonb_build_object('kind', 'email', 'key', 'email:' || em.id, 'tool', 'inbox', 'prompt', 'check my inbox',
        'urgent', em.category = 'never',
        'text', case when em.category = 'never' then 'Reply personally to ' else 'Reply to ' end
          || coalesce(nullif(trim(em.from_name), ''), em.from_address, 'a sender')
          || coalesce(': "' || left(nullif(trim(em.subject), ''), 60) || case when length(em.subject) > 60 then '…' else '' end || '"', '')
          || ', unread since ' || to_char(em.received_at at time zone 'Europe/London',
               case when (em.received_at at time zone 'Europe/London')::date = today then 'HH24:MI' else 'FMDy HH24:MI' end)
          || case when n_em > 1 then ', and ' || (n_em - 1) || ' more unread' else '' end);
    end if;
  end if;

  if p_slot = 'midday' then
    stats := jsonb_build_array(
      jsonb_build_object('label', 'CVs sent', 'value', cv || ' of ' || share_cv, 'ok', cv >= share_cv),
      jsonb_build_object('label', 'Interview requests', 'value', ir || ' of ' || share_ir, 'ok', ir >= share_ir),
      jsonb_build_object('label', 'Queue', 'value', done_today || ' done, ' || open_items || ' open', 'ok', open_items = 0),
      jsonb_build_object('label', 'Calls', 'value', calls || case when untagged > 0 then ' · ' || untagged || ' to clients untagged' else '' end, 'ok', untagged = 0),
      jsonb_build_object('label', 'Week: BD · client calls', 'value', bd_a || ' · ' || cc_a
        || case when bd_l + cc_l > 0 then ' (+' || bd_l || ' · ' || cc_l || ' untagged)' else '' end, 'ok', true));
    for it in select i from jsonb_array_elements(q->'items') i where i->>'kind' = 'offer' limit 1 loop
      cand := cand || jsonb_build_object('kind', 'offer', 'key', it->>'item_key', 'tool', 'action_queue', 'prompt', 'prep my queue',
        'candidate_slug', it->>'candidate_slug', 'job_slug', it->>'job_slug',
        'text', split_part(it->>'action', ':', 1) || ' on ' || coalesce(it->>'who', 'the candidate') || ' for ' || coalesce(it->>'job', 'the role')
          || coalesce(':' || nullif(substr(it->>'action', strpos(it->>'action', ':') + 1), ''), ''));
    end loop;
    if (em_item->>'urgent')::boolean then cand := cand || em_item; end if;
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
    if em_item is not null and not (em_item->>'urgent')::boolean then cand := cand || em_item; end if;
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
    -- Today's untagged client-contact calls, each with the suggested category from likely_call_type().
    -- The message shows every one; nothing is written until the recruiter presses the button.
    with c as (
      select a.recruitcrm_id id, a.call_started_on, a.duration_seconds, a.related_to slug
        from call_activity a
       where a.consultant_recruitcrm_id = p_consultant and a.custom_call_type is null and a.related_to_type = 'contact'
         and a.duration_seconds >= 30 and (a.call_started_on at time zone 'Europe/London')::date = today
       order by a.call_started_on limit 8)
    select coalesce(jsonb_agg(jsonb_build_object(
        'id', c.id, 'at', to_char(c.call_started_on at time zone 'Europe/London', 'HH24:MI'), 'minutes', round(c.duration_seconds / 60.0, 1),
        'with', ct.name, 'company', cl.company_name, 'type', l.type, 'why', l.why)
        order by c.call_started_on), '[]'::jsonb)
      into tagcalls from c
      left join contacts ct on ct.slug = c.slug
      left join clients cl on cl.company_slug = ct.company_slug and cl.deleted_at is null
      cross join lateral public.likely_call_type(c.slug) l;
    if jsonb_array_length(tagcalls) > 0 then
      cand := cand || jsonb_build_object('kind', 'tag_calls', 'key', 'tag:' || today, 'tool', 'call_tagging', 'prompt', '/tagcalls',
        'calls', tagcalls,
        'text', 'Tag today''s ' || jsonb_array_length(tagcalls) || case when jsonb_array_length(tagcalls) = 1 then ' call' else ' calls' end
          || ' to clients so BD and client calls count');
    end if;
    if em_item is not null then cand := cand || em_item; end if;
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
      -- 0148: the week against last week, on the same definitions as weekly_kpis.
      select jsonb_build_object(
          'cv', count(*) filter (where e.stage_metric = 'cv_sent'), 'ir', count(*) filter (where e.stage_metric = 'interview_request'),
          'fi', count(*) filter (where e.stage_metric = 'first_interview'))
        into lw from candidate_stage_latest e join jobs j on j.slug = e.job_slug and j.deleted_at is null
       where e.consultant_id = p_consultant and e.event_date >= date_trunc('week', today)::date - 7 and e.event_date < date_trunc('week', today)::date;
      stats := stats || jsonb_build_array(jsonb_build_object('label', 'Against last week', 'value',
        'CVs ' || wk_cv || ' (' || (lw->>'cv') || ') · req ' || coalesce(wk->'interview_request'->>'actual', '0') || ' (' || (lw->>'ir') || ') · 1st '
          || coalesce(wk->'first_interview'->>'actual', '0') || ' (' || (lw->>'fi') || ')', 'ok', wk_cv >= (lw->>'cv')::int));
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
    -- 0148: the three biggest deals at Offered, named, so the chase has somewhere to start.
    select jsonb_agg(o order by v desc) into offers from (
      select jsonb_build_object('job', coalesce(j.title, d.deal_name), 'client', cl.company_name, 'value', d.deal_value) o, d.deal_value v
        from deals d left join jobs j on j.slug = d.job_slug left join clients cl on cl.company_slug = d.company_slug and cl.deleted_at is null
       where d.deleted_at is null and d.deal_stage = 'Offered' and d.owner_recruitcrm_id = p_consultant
       order by d.deal_value desc nulls last limit 3) s;
    if offers is not null or (bill->>'quarterly_target' is not null and coalesce((bill->>'won_qtr')::numeric, 0) < exp_bill) then
      cand := cand || jsonb_build_object('kind', 'billing', 'key', 'billing:' || today, 'tool', 'billing', 'prompt', '/billing',
        'text', case when bill->>'quarterly_target' is not null and coalesce((bill->>'won_qtr')::numeric, 0) < exp_bill
                     then 'Billing is behind the pace for week ' || weeks_in || ' of 13. ' else '' end
          || coalesce('Offers to close: ' || (select string_agg((o->>'job') || coalesce(' at ' || (o->>'client'), '')
               || coalesce(' (£' || to_char((o->>'value')::numeric, 'FM999,999,999') || ')', ''), '; ') from jsonb_array_elements(offers) o),
             'No offers in play: the interviews this week are where the quarter comes from'));
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
            or (a->>'kind' in ('feedback', 'unbooked', 'email') and not (a->>'key' = any(prev_keys)))
            or (a->>'kind' not in ('feedback', 'unbooked', 'email') and not (a->>'kind' = any(prev_kinds))))
     order by ord limit 3) s;
  select coalesce(array_agg(a->>'tool'), '{}') into suggested from jsonb_array_elements(actions) a;

  if p_slot = 'midday' then
    headline := case when dow <= 2 then 'Your midday check, ' || me.first_name || '. Early in the week'
                     when ahead then 'Your midday check, ' || me.first_name || '. Ahead of the week'
                     when cv >= share_cv and open_items = 0 then 'Your midday check, ' || me.first_name || '. On plan'
                     else 'Your midday check, ' || me.first_name end;
    -- Ahead with nothing urgent, or on plan with nothing to do: one line, no stats.
    if ahead and not exists (select 1 from jsonb_array_elements(actions) a where a->>'kind' in ('offer', 'unbooked', 'feedback') or a->>'urgent' = 'true') then
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
                 (4, 'prep my queue', 'drafts the admin for every call and chase on your list today', 'action_queue'),
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
