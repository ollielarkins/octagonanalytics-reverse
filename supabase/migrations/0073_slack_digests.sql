-- 0073_slack_digests.sql
-- The three digests delivered to Slack instead of email.
--
-- Email was built first (0071/0072) but cannot send: RESEND_API_KEY has never been set on this
-- project. Slack already works and is already proven - admin_webhook_url has returned ok. So this
-- delivers the same three digests through the channel that exists today, using the same digest_*
-- functions as the source. Nothing here duplicates the reporting logic; only the rendering differs.
--
-- The email path is deliberately left in place and scheduled. When a Resend key is set it starts
-- working with no further change, and post_digest() can simply be unscheduled.
--
-- Cadence is unchanged and still comes from measured behaviour: over 20 working days, 43.5% of
-- stage activity happens before 10:00 and 99.6% by 17:00, so morning lands ahead of the day and
-- evening closes a complete one. There is no midday post.
--
-- PII NOTE: these posts name candidates. That is fine for an internal channel and matches what
-- post_standup already does, but whoever can read the channel can read the names - so point
-- digest_webhook_url at a private channel, not a shared or guest-accessible one.

-- Slack mrkdwn needs only these three escaped; everything else is literal.
create or replace function public.slack_escape(t text)
returns text language sql immutable as
$function$ select replace(replace(replace(coalesce(t,''),'&','&amp;'),'<','&lt;'),'>','&gt;') $function$;

-- A two-column stat grid. Slack caps a fields array at 10.
create or replace function public.slack_fields(p jsonb)
returns jsonb language sql immutable as
$function$
  select jsonb_build_object('type','section','fields',
    (select jsonb_agg(jsonb_build_object('type','mrkdwn','text','*'||(e->>'label')||'*'||E'\n'||(e->>'value')))
     from (select e from jsonb_array_elements(p) e limit 10) s))
$function$;

create or replace function public.slack_section(t text)
returns jsonb language sql immutable as
$function$ select jsonb_build_object('type','section','text',
  jsonb_build_object('type','mrkdwn','text', left(t, 2900))) $function$;

create or replace function public.slack_context(t text)
returns jsonb language sql immutable as
$function$ select jsonb_build_object('type','context','elements',
  jsonb_build_array(jsonb_build_object('type','mrkdwn','text', left(t, 2900)))) $function$;

-- Cold roles get their own renderer because two things were wrong on the first pass and both were
-- silent: cold_jobs returns `job_title`, not `title`, so reading x->>'title' produced blank lines
-- rather than an error; and 8 of the 75 currently-cold roles have days_since_activity = NULL,
-- meaning they have had NO activity ever, not that the figure is missing. Those sort to the top and
-- say so - an open role nobody has touched since it was raised is worth more attention than one
-- that has merely gone quiet. One had been open since 17/06/2026 untouched.
create or replace function public.slack_cold_roles(p_jobs jsonb, p_limit integer default 10)
returns text language sql stable set search_path to 'public'
as $function$
  select coalesce(string_agg(line, E'\n'), '_none_') from (
    select '• '||public.slack_escape(x->>'job_title')||' · '||
           public.slack_escape(coalesce(nullif(x->>'client',''),'no client on record'))||' · '||
           case when x->>'days_since_activity' is null
                then ':heavy_exclamation_mark: *no activity ever* (opened '||
                     coalesce(to_char((x->>'opened')::date,'DD/MM/YYYY'),'?')||')'
                else (x->>'days_since_activity')||'d quiet' end as line
    from jsonb_array_elements(p_jobs) x
    order by coalesce((x->>'days_since_activity')::int, 2147483647) desc
    limit p_limit) s;
$function$;

create or replace function public.post_digest(p_kind text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  d jsonb; hook text; blocks jsonb; header text; fallback text;
  body text; health jsonb; healthline text; n int;
begin
  if p_kind not in ('morning','evening','weekly') then
    return jsonb_build_object('error', 'unknown kind: '||p_kind);
  end if;

  -- Prefer a dedicated channel; fall back to the admin webhook so this works the moment it ships.
  select value into hook from app_settings where key = 'digest_webhook_url' and coalesce(value,'') <> '';
  if hook is null then
    select value into hook from app_settings where key = 'admin_webhook_url' and coalesce(value,'') <> '';
  end if;

  if p_kind = 'morning' then
    d := public.digest_morning();
    header := 'Octagon Morning Brief — '||to_char(current_date,'Dy DD/MM');

    blocks := jsonb_build_array(
      jsonb_build_object('type','header','text',jsonb_build_object('type','plain_text','text',left(header,150))),
      public.slack_fields(jsonb_build_array(
        jsonb_build_object('label','Offers aging','value',jsonb_array_length(d->'chase'->'aging_offers')::text),
        jsonb_build_object('label','To book in','value',jsonb_array_length(d->'chase'->'unbooked_requests')::text),
        jsonb_build_object('label','Awaiting feedback','value',jsonb_array_length(d->'chase'->'awaiting_feedback')::text),
        jsonb_build_object('label','Cold roles','value',jsonb_array_length(d->'cold_roles')::text))),
      jsonb_build_object('type','divider'));

    select coalesce(string_agg('• *'||public.slack_escape(x->>'candidate')||'* — offer out '||
             (x->>'days_since_offer')||'d · '||public.slack_escape(x->>'job_title')||' · '||
             public.slack_escape(x->>'consultant'), E'\n'), '_none_')
      into body from (select x from jsonb_array_elements(d->'chase'->'aging_offers') x limit 6) s;
    blocks := blocks || public.slack_section('*Aging offers*'||E'\n'||body||
      E'\n_An unanswered offer is the most expensive thing on any desk._');

    select coalesce(string_agg('• *'||public.slack_escape(x->>'candidate')||'* — '||
             (x->>'days_waiting')||'d waiting · '||public.slack_escape(x->>'job')||' · '||
             public.slack_escape(x->>'consultant'), E'\n'), '_none_')
      into body from (select x from jsonb_array_elements(d->'chase'->'unbooked_requests') x limit 6) s;
    blocks := blocks || public.slack_section('*Interview requests never booked*'||E'\n'||body);

    select coalesce(string_agg('• *'||public.slack_escape(x->>'candidate')||'* — '||
             (x->>'days_since')||'d since interview · '||public.slack_escape(x->>'job')||' · '||
             public.slack_escape(x->>'consultant'), E'\n'), '_none_')
      into body from (select x from jsonb_array_elements(d->'chase'->'awaiting_feedback') x limit 6) s;
    blocks := blocks || public.slack_section('*Interviewed, nothing logged since*'||E'\n'||body||
      E'\n_Silence in the system, not proof feedback was never given — worth a check, not a telling-off._');

    blocks := blocks || public.slack_section(
      '*Previous working day* ('||to_char((d->>'previous_working_day')::date,'DD/MM')||')'||E'\n'||
      (d->'yesterday'->>'cv_sent')||' CV sent · '||(d->'yesterday'->>'interview_request')||' IV requests · '||
      (d->'yesterday'->>'first_interview')||' 1st interviews · '||(d->'yesterday'->>'placed')||' placed'||E'\n'||
      (d->'yesterday'->>'calls')||' calls ('||(d->'yesterday'->>'bd_calls')||' BD, '||
      (d->'yesterday'->>'client_calls')||' client)'||E'\n\n'||
      '*Week to date* — '||(d->'week_to_date'->>'cv_sent')||' CV sent · '||
      (d->'week_to_date'->>'interview_request')||' IV requests · '||
      (d->'week_to_date'->>'first_interview')||' 1st interviews');

    fallback := header||' — '||
      (jsonb_array_length(d->'chase'->'aging_offers') + jsonb_array_length(d->'chase'->'unbooked_requests')
       + jsonb_array_length(d->'chase'->'awaiting_feedback'))::text||' to chase';

  elsif p_kind = 'evening' then
    d := public.digest_evening();
    header := 'Octagon Day End — '||to_char(current_date,'Dy DD/MM');

    blocks := jsonb_build_array(
      jsonb_build_object('type','header','text',jsonb_build_object('type','plain_text','text',left(header,150))),
      public.slack_fields(jsonb_build_array(
        jsonb_build_object('label','CV sent','value',(d->'totals'->>'cv_sent')),
        jsonb_build_object('label','IV requests','value',(d->'totals'->>'interview_request')),
        jsonb_build_object('label','1st interviews','value',(d->'totals'->>'first_interview')),
        jsonb_build_object('label','Placed','value',(d->'totals'->>'placed')))),
      jsonb_build_object('type','divider'));

    n := jsonb_array_length(d->'placements');
    if n > 0 then
      select string_agg('• *'||public.slack_escape(x->>'candidate_job')||'* · '||
               public.slack_escape(x->>'consultant')||' · '||
               case when x->>'deal_value' is null then ':warning: no Won deal yet'
                    else '£'||to_char((x->>'deal_value')::numeric,'FM999,999,999') end, E'\n')
        into body from jsonb_array_elements(d->'placements') x;
      blocks := blocks || public.slack_section('*Placements today*'||E'\n'||body||
        E'\n_A placement bills only once the deal is moved to Won with a value entered._');
    end if;

    select coalesce(string_agg('• '||public.slack_escape(x->>'name')||' — '||(x->>'cv_sent')||' CV · '||
             (x->>'interview_request')||' IV req · '||(x->>'first_interview')||' 1st'||
             case when (x->>'placed')::int > 0 then ' · '||(x->>'placed')||' placed' else '' end, E'\n'), '_no activity recorded_')
      into body from (select x from jsonb_array_elements(d->'by_consultant') x limit 15) s;
    blocks := blocks || public.slack_section('*By consultant*'||E'\n'||body);

    blocks := blocks || public.slack_section(
      '*Calls*'||E'\n'||(d->'calls'->>'total')||' total · '||(d->'calls'->>'connected')||' connected ('||
      coalesce(d->'calls'->>'connect_rate','0')||'%) · '||(d->'calls'->>'bd')||' BD · '||
      (d->'calls'->>'client')||' client'||
      case when coalesce((d->'calls'->>'tagged_pct')::numeric,0) < 30
        then E'\n:warning: Only '||coalesce(d->'calls'->>'tagged_pct','0')||
             '% of today''s calls are categorised, so BD and client figures are a floor, not an actual.'
        else '' end);

    n := jsonb_array_length(d->'new_jobs');
    if n > 0 then
      select string_agg('• '||public.slack_escape(x->>'title')||' · '||public.slack_escape(x->>'owner')||' · '||
               case when (x->>'job_order_form')::boolean then 'form logged' else ':warning: no job order form' end, E'\n')
        into body from jsonb_array_elements(d->'new_jobs') x;
      blocks := blocks || public.slack_section('*New jobs today*'||E'\n'||body);
    end if;

    fallback := header||' — '||(d->'totals'->>'cv_sent')||' CVs, '||
      (d->'totals'->>'first_interview')||' interviews';

  else
    d := public.digest_weekly();
    header := 'Octagon Week Ahead — '||to_char(current_date,'Dy DD/MM');

    blocks := jsonb_build_array(
      jsonb_build_object('type','header','text',jsonb_build_object('type','plain_text','text',left(header,150))),
      public.slack_fields(jsonb_build_array(
        jsonb_build_object('label','Cold roles','value',jsonb_array_length(d->'cold_roles')::text),
        jsonb_build_object('label','New jobs last week','value',coalesce(d->'new_jobs'->'totals'->>'new_jobs','0')),
        jsonb_build_object('label','Missing job order form','value',coalesce(d->'new_jobs'->'totals'->>'missing_job_order_form','0')),
        jsonb_build_object('label','Placed last week','value',coalesce(d->'last_week'->'funnel'->'totals'->>'placed','0')))),
      jsonb_build_object('type','divider'));

    blocks := blocks || public.slack_section(
      '*Last week''s funnel* ('||to_char((d->'last_week'->>'from')::date,'DD/MM')||' – '||
      to_char((d->'last_week'->>'to')::date - 1,'DD/MM')||')'||E'\n'||
      coalesce(d->'last_week'->'funnel'->'totals'->>'cv_sent','0')||' CV sent → '||
      coalesce(d->'last_week'->'funnel'->'totals'->>'interview_request','0')||' IV req → '||
      coalesce(d->'last_week'->'funnel'->'totals'->>'first_interview','0')||' 1st → '||
      coalesce(d->'last_week'->'funnel'->'totals'->>'second_interview','0')||' 2nd → '||
      coalesce(d->'last_week'->'funnel'->'totals'->>'third_interview','0')||' 3rd → '||
      coalesce(d->'last_week'->'funnel'->'totals'->>'offered','0')||' offered → '||
      coalesce(d->'last_week'->'funnel'->'totals'->>'placed','0')||' placed');

    blocks := blocks || public.slack_section(
      '*Job order forms*'||E'\n'||
      coalesce(d->'new_jobs'->'totals'->>'with_job_order_form','0')||' of '||
      coalesce(d->'new_jobs'->'totals'->>'new_jobs','0')||' new roles have one ('||
      coalesce(d->'new_jobs'->'totals'->>'form_completion_pct','0')||'%)'||
      E'\n_Missing means the note was never logged, not that the qualifying call never happened._');

    body := public.slack_cold_roles(d->'cold_roles', 10);
    blocks := blocks || public.slack_section('*Cold open roles*'||E'\n'||body);

    fallback := header||' — '||jsonb_array_length(d->'cold_roles')::text||' cold roles';
  end if;

  health := d->'health';
  healthline := case when health->>'overall' = 'ok' then 'Sync healthy.'
                else ':rotating_light: *Sync is not healthy — figures may be stale.*' end;

  blocks := blocks || public.slack_context(healthline||
    ' Funnel counts distinct candidate-job pairs credited to whoever moved the stage.'||
    ' BD and client calls count only categorised Devyce calls and under-report.'||
    ' Candidate names are internal only.');

  if hook is null then
    return jsonb_build_object('posted', false, 'reason', 'no digest_webhook_url or admin_webhook_url set',
                              'kind', p_kind, 'fallback', fallback);
  end if;

  perform net.http_post(
    url := hook,
    headers := '{"Content-Type":"application/json"}'::jsonb,
    body := jsonb_build_object('text', fallback, 'blocks', blocks));

  return jsonb_build_object('posted', true, 'kind', p_kind, 'fallback', fallback,
                            'blocks', jsonb_array_length(blocks));
end;
$function$;

revoke all on function public.post_digest(text) from public, anon, authenticated;
grant execute on function public.post_digest(text) to service_role;

-- Same DST-proof gate as the email path: fire at both candidate UTC hours, keep the London one.
create or replace function public.post_digest_if_due(p_kind text, p_london_hour integer)
returns void language plpgsql security definer set search_path to 'public'
as $function$
begin
  if extract(hour from (now() at time zone 'Europe/London'))::int <> p_london_hour then
    return;
  end if;
  perform public.post_digest(p_kind);
end;
$function$;

revoke all on function public.post_digest_if_due(text, integer) from public, anon, authenticated;

select cron.schedule('digest-slack-morning', '30 6,7 * * 1-5',
  $$select public.post_digest_if_due('morning', 7);$$);
select cron.schedule('digest-slack-evening', '30 16,17 * * 1-5',
  $$select public.post_digest_if_due('evening', 17);$$);
select cron.schedule('digest-slack-weekly', '0 7,8 * * 1',
  $$select public.post_digest_if_due('weekly', 8);$$);

-- The email jobs are unscheduled rather than deleted: 0071/0072 stay in place, and re-enabling them
-- once a Resend key exists is three cron.schedule calls, not a rebuild.
select cron.unschedule('digest-morning');
select cron.unschedule('digest-evening');
select cron.unschedule('digest-weekly');
