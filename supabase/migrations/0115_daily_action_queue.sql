-- 0115_daily_action_queue.sql
-- Priority 4 (Bhav, 20/10/2026): a Slack DM before 9am to each consultant with 5-10 ranked calls.
-- Decided 26/10/2026: the DM lists ranked actions and hands drafting to the consultant's own Claude
-- ("prep my queue"), keeping the 13/10/2026 rule of no server-side AI. Pilot with Will Drake, Keelan
-- Riley and Adam Barnett, shadowed to Oliver first. Thresholds as proposed, Bhav's "to agree":
--   1 offer out with no answer, 3+ days          all
--   2 interview on the next working day (prep)   all   (diary_digest, 0110)
--   3 interview held, nothing logged (feedback)  all   (diary_digest, 0110)
--   4 interview request unbooked, 2+ days        3
--   5 CV sent, no response, 5+ working days      3     (latest stage on an open job, last 30 days)
--   6 cold job, 7+ days without activity         2
--   7 behind on BD calls this week (Tue-Fri)     1 line, from tagged BD calls only
-- At most 10 items; the totals say how many there were before the caps.
-- Client meetings for the quarter are left out until meetings are typed (121 of 159 untyped).

create or replace function public.action_queue(p_consultant bigint)
returns jsonb language sql stable security definer set search_path = public, pg_temp
as $function$
  with me as (select recruitcrm_id, name from consultants where recruitcrm_id = p_consultant and deleted_at is null),
  wd5 as (   -- the date five working days ago
    select d::date d from generate_series(current_date - 14, current_date - 1, interval '1 day') d
    where extract(isodow from d) < 6 order by d desc offset 4 limit 1
  ),
  dd as (select x from jsonb_array_elements(public.diary_digest()->'by_consultant') x, me where x->>'consultant' = me.name),
  offers as (
    select 1 rank, 'offer' kind, x->>'candidate' who, x->>'job_title' job, null::text client,
           (x->>'days_since_offer')::int age, 'Offer out '||(x->>'days_since_offer')||' days: call the candidate, then the client' action
    from jsonb_array_elements(public.stalled_report(10, 3, 60)->'aging_offers') x, me where x->>'consultant' = me.name
  ),
  prep as (
    select 2, 'prep', p->>'candidate', p->>'job', p->>'client', 0,
           'Interview '||to_char((select (public.diary_digest()->>'prep_day')::date), 'Dy')||' '||(p->>'time')||': prep call'
    from dd, jsonb_array_elements(dd.x->'prep') p
  ),
  fb as (
    select 3, 'feedback', f->>'candidate', f->>'job', f->>'client', 0,
           'Interviewed '||(f->>'held')||', nothing logged since: feedback call to the client'
    from dd, jsonb_array_elements(dd.x->'feedback_due') f
  ),
  unbooked as (
    select 4, 'unbooked', x->>'candidate', x->>'job', null::text, (x->>'days_waiting')::int,
           'Interview request '||(x->>'days_waiting')||' days unbooked: booking call'
    from jsonb_array_elements(public.interview_requests_unbooked(30)->'requests') x, me
    where x->>'consultant' = me.name and (x->>'days_waiting')::int >= 2
  ),
  latest as (
    select distinct on (e.candidate_slug, e.job_slug) e.candidate_name, e.job_title, e.stage_metric, e.event_date, e.consultant
    from candidate_stage_events e join jobs j on j.slug = e.job_slug and j.status = 'Open' and j.deleted_at is null
    where e.event_date >= current_date - 30
    order by e.candidate_slug, e.job_slug, e.event_timestamp desc
  ),
  cvs as (
    select 5, 'cv_chase', l.candidate_name, l.job_title, null::text, (current_date - l.event_date),
           'CV sent '||to_char(l.event_date, 'DD/MM')||', no response: chase call'
    from latest l, me, wd5 where l.stage_metric = 'cv_sent' and l.consultant = me.name and l.event_date <= wd5.d
  ),
  cold as (
    select 6, 'cold_job', null::text, x->>'job_title', x->>'client', (x->>'days_since_activity')::int,
           'Cold '||(x->>'days_since_activity')||' days: Boolean search, shortlist and InMails'
    from jsonb_array_elements(public.cold_jobs(7, null, 100)->'jobs') x, me where x->>'consultant' = me.name
  ),
  bd as (
    select 7, 'bd', null::text, null::text, null::text, 0,
           'BD calls: '||n||' tagged this week against 5. A prospect list and spec pitches would close the gap'
    from (select count(*) n from call_activity ca, me
          where ca.consultant_recruitcrm_id = me.recruitcrm_id and ca.custom_call_type = 'Contact - Prospect (BD)'
            and (ca.call_started_on at time zone 'Europe/London')::date >= date_trunc('week', current_date)::date) c
    where extract(isodow from current_date) between 2 and 5 and n < extract(isodow from current_date) - 1
  ),
  allrows as (
    select * from offers union all select * from prep union all select * from fb union all select * from unbooked
    union all select * from cvs union all select * from cold union all select * from bd
  ),
  numbered as (
    select a.*, row_number() over (partition by kind order by age desc nulls last, who) n_in_kind from allrows a
  ),
  capped as (
    select * from numbered
    where n_in_kind <= case kind when 'unbooked' then 3 when 'cv_chase' then 3 when 'cold_job' then 2 when 'bd' then 1 else 1000 end
    order by rank, age desc nulls last, who limit 10
  )
  select jsonb_build_object(
    'consultant', (select name from me),
    'for_date', current_date,
    'total', (select count(*) from allrows),
    'by_kind', (select coalesce(jsonb_object_agg(kind, n), '{}'::jsonb) from (select kind, count(*) n from allrows group by kind) k),
    'items', coalesce((select jsonb_agg(jsonb_build_object('kind', kind, 'action', action, 'who', who, 'job', job, 'client', client)
                         order by rank, age desc nulls last, who) from capped), '[]'::jsonb));
$function$;
revoke execute on function public.action_queue(bigint) from public, anon, authenticated;
grant execute on function public.action_queue(bigint) to service_role;

-- Pilot and shadow settings. Shadow on: every DM goes to the shadow address, labelled with whose it is.
insert into app_settings (key, value, updated_at) values
  ('action_queue_pilot', '154036,77535,77603', now()),          -- Will Drake, Keelan Riley, Adam Barnett
  ('action_queue_shadow', 'true', now()),
  ('action_queue_shadow_email', 'olarkins@octagongroup.co.uk', now())
on conflict (key) do nothing;

-- 08:30 UK on weekdays. Scheduled at 07:30 and 08:30 UTC; the London-hour check sends once, all year.
create or replace function public.action_queue_if_due(p_london_hour integer)
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
    raise warning 'action_queue_if_due: app_settings.cron_bearer not set, queue skipped';
    return;
  end if;
  perform net.http_post(
    url := 'https://kzcmssldvtjnbwwunuwm.supabase.co/functions/v1/daily-queue',
    headers := hdrs, body := '{}'::jsonb, timeout_milliseconds := 55000);
end;
$function$;
revoke execute on function public.action_queue_if_due(integer) from public, anon, authenticated;

select cron.schedule('daily-action-queue', '30 7,8 * * 1-5', $$select public.action_queue_if_due(8);$$);
insert into cron_manifest (jobname, schedule, note, required)
values ('daily-action-queue', '30 7,8 * * 1-5', 'daily action queue DMs, 08:30 UK', true)
on conflict (jobname) do update set schedule = excluded.schedule, note = excluded.note, required = excluded.required;

-- /map: action_queue counts under 'chasing'. Also files three tools added since 0108 that fell into
-- 'reporting' by default: call_tagging and client_status under 'changes', internal_jd_check under
-- 'admin'. Otherwise identical to 0108.
create or replace function public.feature_area(p_tool text)
returns text language sql immutable set search_path = public, pg_temp as $function$
  select case
    when p_tool = '_session' then null
    when p_tool like 'content:%' or p_tool like 'prompt:%' or p_tool = 'cv_pack' then 'content'
    when p_tool in ('get_dashboard','weekly_kpis','billing','my_day') then 'dashboard'
    when p_tool in ('stalled_report','cold_jobs','awaiting_feedback_report','interview_requests_unbooked','schedule','action_queue') then 'chasing'
    when p_tool = 'match_candidates' then 'matching'
    when p_tool in ('find_candidate','candidate_profile','job_pipeline','job_spec','notes_read','call_notes','files_list','pitch_history','reference_list','off_limit') then 'lookup'
    when p_tool in ('update_hiring_stage','assign_candidate','add_note','create_candidate','update_candidate','create_job','update_job','job_dpe',
                    'create_deal','update_deal','manage_client','manage_assignment','log_activity','meeting_review','hotlist','pitch_candidate','delete_record',
                    'call_tagging','client_status') then 'changes'
    when p_tool in ('send_email','push_tell','eow_email','dpe_email') then 'email'
    when p_tool in ('inbox','draft_reply') then 'inbox'
    when p_tool in ('usage_report','manage_tokens','platform_health','webhook_subscriptions','post_digest','team_insights','internal_jd_check') then 'admin'
    else 'reporting' end
$function$;
