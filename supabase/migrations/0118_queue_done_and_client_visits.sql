-- 0118_queue_done_and_client_visits.sql
-- 26/10/2026, all at once by Oliver's call:
--  1. Queue phase 2: a Done button per call in the 08:30 DM (slack-actions function). Done items are
--     remembered here so they do not come back the next morning, and each item carries a stable key
--     plus the candidate and job slugs, so a Done can be logged as a note in RecruitCRM.
--  2. A typing nudge: client visits only count if meetings are typed, and 121 of 159 were not.
--  3. Priority 6 (Bhav, 20/10/2026): client meetings, at least 2 per consultant per quarter.
--     client_visits() counts them, says who to visit and why; the queue nudges on Mondays and the
--     Week Ahead brief shows everyone's count. The meetings copy now reaches back to the quarter's
--     start (meetings_quarter, daily) and records each meeting's company.

alter table public.meetings add column if not exists company_slug text;

-- Done items. hide_until is set per kind by slack-actions; a prep or feedback key is tied to one
-- meeting, so it never comes back anyway.
create table if not exists public.action_queue_done (
  consultant_recruitcrm_id bigint not null,
  item_key   text not null,
  kind       text,
  hide_until date not null,
  note_written boolean not null default false,
  done_at    timestamptz not null default now(),
  primary key (consultant_recruitcrm_id, item_key)
);
alter table public.action_queue_done enable row level security;
revoke all on table public.action_queue_done from anon, authenticated;

-- diary_digest: adds meeting_id, candidate_slug and job_slug to each prep and feedback item, so the
-- queue can key them and log a Done against the candidate. Otherwise identical to 0111.
create or replace function public.diary_digest()
returns jsonb language sql stable security definer set search_path = public, pg_temp
as $function$
  with nwd as (
    select (current_date + case extract(dow from current_date)::int when 5 then 3 when 6 then 2 else 1 end) d
  ),
  iv as (
    select m.*, co.name consultant, c.name candidate, j.title job, cl.company_name client,
           (m.start_at at time zone 'Europe/London') local_start,
           coalesce(m.end_at, m.start_at + interval '1 hour') ends
    from meetings m
    join consultants co on co.recruitcrm_id = m.owner_recruitcrm_id and co.deleted_at is null
    left join candidates c on c.slug = m.candidate_slug
    left join jobs j on j.slug = m.job_slug
    left join clients cl on cl.company_slug = j.company_slug
    where m.deleted_at is null and m.meeting_type ~* '^candidate' and m.meeting_type ~* 'interview'
  ),
  prep as (
    select * from iv where local_start::date = (select d from nwd)
  ),
  fb as (
    select * from iv
    where candidate_slug is not null
      and local_start::date >= current_date - 4
      and ends + interval '2 hours' < now()
      and not exists (select 1 from call_activity ca where ca.related_to = iv.candidate_slug
                        and ca.custom_call_type ilike '%feedback%' and ca.call_started_on >= iv.start_at)
      and not exists (select 1 from notes n where n.related_to = iv.candidate_slug and n.created_on >= iv.start_at)
      and not exists (select 1 from candidate_stage_events e where e.candidate_slug = iv.candidate_slug
                        and (iv.job_slug is null or e.job_slug = iv.job_slug)
                        and e.event_timestamp > (iv.start_at at time zone 'UTC'))
  ),
  people as (select consultant from prep union select consultant from fb)
  select jsonb_build_object(
    'prep_day', (select d from nwd),
    'synced', (select last_run_at from sync_state where entity = 'meetings'),
    'prep_total', (select count(*) from prep),
    'feedback_total', (select count(*) from fb),
    'by_consultant', coalesce((select jsonb_agg(jsonb_build_object(
        'consultant', p.consultant,
        'prep', (select coalesce(jsonb_agg(jsonb_build_object(
                    'time', to_char(x.local_start, 'HH24:MI'), 'candidate', coalesce(x.candidate, x.title),
                    'job', x.job, 'client', x.client, 'type', x.meeting_type,
                    'meeting_id', x.recruitcrm_id, 'candidate_slug', x.candidate_slug, 'job_slug', x.job_slug) order by x.local_start), '[]'::jsonb)
                 from prep x where x.consultant = p.consultant),
        'feedback_due', (select coalesce(jsonb_agg(jsonb_build_object(
                    'held', to_char(x.local_start, 'Dy DD/MM HH24:MI'), 'candidate', coalesce(x.candidate, x.title),
                    'job', x.job, 'client', x.client,
                    'meeting_id', x.recruitcrm_id, 'candidate_slug', x.candidate_slug, 'job_slug', x.job_slug) order by x.local_start), '[]'::jsonb)
                 from fb x where x.consultant = p.consultant))
      order by p.consultant) from people p), '[]'::jsonb)
  );
$function$;

-- client_visits(p_consultant): client meetings this quarter per active consultant (or one), against
-- the minimum of 2, and up to five clients to visit with the reasons. Visits are meetings typed
-- "Client Meeting"; untyped meetings are counted separately so the gap is visible.
create or replace function public.client_visits(p_consultant bigint default null)
returns jsonb language sql stable security definer set search_path = public, pg_temp
as $function$
  with q as (select date_trunc('quarter', (now() at time zone 'Europe/London'))::date qs,
                    (date_trunc('quarter', (now() at time zone 'Europe/London')) + interval '3 months')::date qe),
  people as (
    select c.id, c.recruitcrm_id, c.name from consultants c
    where c.deleted_at is null and coalesce(c.active, true)
      and (p_consultant is null or c.recruitcrm_id = p_consultant)
  ),
  qm as (
    select m.owner_recruitcrm_id, m.meeting_type, m.start_at, m.company_slug, cl.company_name
    from meetings m cross join q
    left join clients cl on cl.company_slug = m.company_slug
    where m.deleted_at is null
      and (m.start_at at time zone 'Europe/London')::date >= q.qs and (m.start_at at time zone 'Europe/London')::date < q.qe
  ),
  last_visit as (
    select m.company_slug, max(m.start_at) at_ from meetings m
    where m.deleted_at is null and m.meeting_type = 'Client Meeting' and m.company_slug is not null and m.start_at < now()
    group by 1
  ),
  cand as (   -- clients worth a visit, per consultant: their open A/B jobs, and their Won fees in 12 months
    select p.recruitcrm_id, j.company_slug,
           count(*) filter (where j.custom_fields->'13'->>'value' = 'A') a_jobs,
           count(*) filter (where j.custom_fields->'13'->>'value' = 'B') b_jobs
    from people p join jobs j on j.consultant_id = p.id and j.status = 'Open' and j.deleted_at is null
    where j.company_slug is not null and j.custom_fields->'13'->>'value' in ('A','B')
    group by 1, 2
  ),
  won as (
    select d.owner_recruitcrm_id, d.company_slug, sum(d.deal_value) v
    from deals d where d.deal_stage = 'Won' and d.deleted_at is null and d.company_slug is not null
      and coalesce(d.close_date, d.created_date) >= now() - interval '12 months'
    group by 1, 2
  ),
  scored as (
    select coalesce(c.recruitcrm_id, w.owner_recruitcrm_id) recruitcrm_id, coalesce(c.company_slug, w.company_slug) company_slug,
           coalesce(c.a_jobs, 0) a_jobs, coalesce(c.b_jobs, 0) b_jobs, coalesce(w.v, 0) won_12m, lv.at_ last_visit
    from cand c full join won w on w.owner_recruitcrm_id = c.recruitcrm_id and w.company_slug = c.company_slug
    left join last_visit lv on lv.company_slug = coalesce(c.company_slug, w.company_slug)
  ),
  ranked as (
    select s.*, cl.company_name,
           (3 * s.a_jobs + 2 * s.b_jobs + case when s.won_12m > 0 then 2 else 0 end
            + case when s.last_visit is null or s.last_visit < now() - interval '90 days' then 2 else 0 end) score,
           row_number() over (partition by s.recruitcrm_id order by
             (3 * s.a_jobs + 2 * s.b_jobs + case when s.won_12m > 0 then 2 else 0 end
              + case when s.last_visit is null or s.last_visit < now() - interval '90 days' then 2 else 0 end) desc, s.won_12m desc) rn
    from scored s join clients cl on cl.company_slug = s.company_slug and cl.deleted_at is null
    where s.recruitcrm_id in (select recruitcrm_id from people)
  )
  select jsonb_build_object(
    'quarter', jsonb_build_object('from', (select qs from q), 'to_exclusive', (select qe from q)),
    'minimum', 2,
    'consultants', coalesce((select jsonb_agg(jsonb_build_object(
        'consultant', p.name,
        'visits_done', (select count(*) from qm where qm.owner_recruitcrm_id = p.recruitcrm_id and qm.meeting_type = 'Client Meeting' and qm.start_at < now()),
        'visits_booked', (select count(*) from qm where qm.owner_recruitcrm_id = p.recruitcrm_id and qm.meeting_type = 'Client Meeting' and qm.start_at >= now()),
        'untyped_meetings', (select count(*) from qm where qm.owner_recruitcrm_id = p.recruitcrm_id and qm.meeting_type is null),
        'visits', (select coalesce(jsonb_agg(jsonb_build_object('client', coalesce(qm.company_name, '(no company linked)'),
                     'when', to_char(qm.start_at at time zone 'Europe/London', 'DD/MM/YYYY'), 'booked', qm.start_at >= now()) order by qm.start_at), '[]'::jsonb)
                   from qm where qm.owner_recruitcrm_id = p.recruitcrm_id and qm.meeting_type = 'Client Meeting'),
        'suggestions', (select coalesce(jsonb_agg(jsonb_build_object(
                     'client', r.company_name, 'company_slug', r.company_slug,
                     'why', concat_ws('; ',
                        case when r.a_jobs > 0 then r.a_jobs || ' live A-grade job' || case when r.a_jobs > 1 then 's' else '' end end,
                        case when r.b_jobs > 0 then r.b_jobs || ' live B-grade job' || case when r.b_jobs > 1 then 's' else '' end end,
                        case when r.won_12m > 0 then 'Won fees in the last 12 months: £' || to_char(r.won_12m, 'FM999,999,999') end,
                        case when r.last_visit is null then 'no visit on record'
                             when r.last_visit < now() - interval '90 days' then 'last visit ' || to_char(r.last_visit, 'DD/MM/YYYY') end))
                     order by r.rn), '[]'::jsonb)
                   from ranked r where r.recruitcrm_id = p.recruitcrm_id and r.rn <= 5))
      order by p.name) from people p), '[]'::jsonb),
    'note', 'Visits are meetings typed Client Meeting in RecruitCRM. Untyped meetings cannot count: meeting_review types them. Suggestions rank live A and B grade jobs, Won fees in the last 12 months and how long since the last visit.');
$function$;
revoke execute on function public.client_visits(bigint) from public, anon, authenticated;
grant execute on function public.client_visits(bigint) to service_role;

-- action_queue v3: every item has a stable key and, where there is one, the candidate and job slug;
-- items marked done stay hidden until hide_until; and three closing lines that are not calls:
-- stale stages (0116), untyped meetings (Mondays and Thursdays) and client visits (Mondays, while
-- fewer than 2 are done or booked this quarter).
create or replace function public.action_queue(p_consultant bigint)
returns jsonb language sql stable security definer set search_path = public, pg_temp
as $function$
  with me as (select recruitcrm_id, name from consultants where recruitcrm_id = p_consultant and deleted_at is null),
  done as (select item_key from action_queue_done where consultant_recruitcrm_id = p_consultant and hide_until >= current_date),
  wd5 as (   -- the date five working days ago
    select d::date d from generate_series(current_date - 14, current_date - 1, interval '1 day') d
    where extract(isodow from d) < 6 order by d desc offset 4 limit 1
  ),
  dd as (select x from jsonb_array_elements(public.diary_digest()->'by_consultant') x, me where x->>'consultant' = me.name),
  offers as (
    select 1 rank, 'offer' kind, 'offer:'||(x->>'candidate_slug')||':'||(x->>'job_slug') item_key,
           x->>'candidate' who, x->>'job_title' job, null::text client, x->>'candidate_slug' candidate_slug, x->>'job_slug' job_slug,
           (x->>'days_since_offer')::int age, 'Offer out '||(x->>'days_since_offer')||' days: call the candidate, then the client' action
    from jsonb_array_elements(public.stalled_report(10, 3, 60)->'aging_offers') x, me
    where x->>'consultant' = me.name and (x->>'days_since_offer')::int <= 21
  ),
  prep as (
    select 2, 'prep', 'prep:'||(p->>'meeting_id'), p->>'candidate', p->>'job', p->>'client', p->>'candidate_slug', p->>'job_slug', 0,
           'Interview '||to_char((select (public.diary_digest()->>'prep_day')::date), 'Dy')||' '||(p->>'time')||': prep call'
    from dd, jsonb_array_elements(dd.x->'prep') p
  ),
  fb as (
    select 3, 'feedback', 'feedback:'||(f->>'meeting_id'), f->>'candidate', f->>'job', f->>'client', f->>'candidate_slug', f->>'job_slug', 0,
           'Interviewed '||(f->>'held')||', nothing logged since: feedback call to the client'
    from dd, jsonb_array_elements(dd.x->'feedback_due') f
  ),
  ir as (   -- unbooked interview requests, with the slugs interview_requests_unbooked does not return
    select x->>'candidate' who, x->>'job' job, (x->>'days_waiting')::int days,
           (select e.candidate_slug from candidate_stage_events e where e.candidate_name = x->>'candidate' and e.job_title = x->>'job'
              and e.stage_metric = 'interview_request' order by e.event_timestamp desc limit 1) candidate_slug,
           (select e.job_slug from candidate_stage_events e where e.candidate_name = x->>'candidate' and e.job_title = x->>'job'
              and e.stage_metric = 'interview_request' order by e.event_timestamp desc limit 1) job_slug
    from jsonb_array_elements(public.interview_requests_unbooked(30)->'requests') x, me where x->>'consultant' = me.name
  ),
  unbooked as (
    select 4, 'unbooked', 'unbooked:'||coalesce(ir.candidate_slug, ir.who)||':'||coalesce(ir.job_slug, ir.job),
           ir.who, ir.job, null::text, ir.candidate_slug, ir.job_slug, ir.days,
           'Interview request '||ir.days||' days unbooked: booking call'
    from ir where ir.days between 2 and 14
  ),
  -- 0116: offers older than 21 days and requests unbooked for over 14 are almost always stages nobody
  -- updated, not live work, so they make one clean-up line instead of leading the list.
  stale as (
    select x->>'candidate' who, (x->>'days_since_offer')::int age from jsonb_array_elements(public.stalled_report(10, 3, 60)->'aging_offers') x, me
    where x->>'consultant' = me.name and (x->>'days_since_offer')::int > 21
    union all
    select ir.who, ir.days from ir where ir.days > 14
  ),
  latest as (
    select distinct on (e.candidate_slug, e.job_slug) e.candidate_slug, e.job_slug, e.candidate_name, e.job_title, e.stage_metric, e.event_date, e.consultant
    from candidate_stage_events e join jobs j on j.slug = e.job_slug and j.status = 'Open' and j.deleted_at is null
    where e.event_date >= current_date - 30
    order by e.candidate_slug, e.job_slug, e.event_timestamp desc
  ),
  cvs as (
    select 5, 'cv_chase', 'cv:'||l.candidate_slug||':'||l.job_slug, l.candidate_name, l.job_title, null::text, l.candidate_slug, l.job_slug,
           (current_date - l.event_date), 'CV sent '||to_char(l.event_date, 'DD/MM')||', no response: chase call'
    from latest l, me, wd5 where l.stage_metric = 'cv_sent' and l.consultant = me.name and l.event_date <= wd5.d
  ),
  cold as (
    select 6, 'cold_job', 'cold:'||coalesce(x->>'job_title','')||':'||coalesce(x->>'client',''), null::text, x->>'job_title', x->>'client', null::text, null::text,
           (x->>'days_since_activity')::int, 'Cold '||(x->>'days_since_activity')||' days: Boolean search, shortlist and InMails'
    from jsonb_array_elements(public.cold_jobs(7, null, 100)->'jobs') x, me where x->>'consultant' = me.name
  ),
  bd as (
    select 7, 'bd', 'bd:'||to_char(current_date, 'IYYY-IW'), null::text, null::text, null::text, null::text, null::text, 0,
           'BD calls: '||n||' tagged this week against 5. A prospect list and spec pitches would close the gap'
    from (select count(*) n from call_activity ca, me
          where ca.consultant_recruitcrm_id = me.recruitcrm_id and ca.custom_call_type = 'Contact - Prospect (BD)'
            and (ca.call_started_on at time zone 'Europe/London')::date >= date_trunc('week', current_date)::date) c
    where extract(isodow from current_date) between 2 and 5 and n < extract(isodow from current_date) - 1
  ),
  allrows as (
    select * from (
      select * from offers union all select * from prep union all select * from fb union all select * from unbooked
      union all select * from cvs union all select * from cold union all select * from bd) a
    where a.item_key not in (select item_key from done)
  ),
  numbered as (
    select a.*, row_number() over (partition by kind order by age desc nulls last, who) n_in_kind from allrows a
  ),
  capped as (
    select * from numbered
    where n_in_kind <= case kind when 'unbooked' then 3 when 'cv_chase' then 3 when 'cold_job' then 2 when 'bd' then 1 else 1000 end
    order by rank, age desc nulls last, who limit 10
  ),
  untyped as (
    select count(*) n from meetings m, me
    where m.owner_recruitcrm_id = me.recruitcrm_id and m.deleted_at is null and m.meeting_type is null
      and (m.start_at at time zone 'Europe/London')::date >= date_trunc('quarter', current_date)::date
      and not exists (select 1 from meeting_type_skips s where s.meeting_id = m.recruitcrm_id)
  ),
  cv as (select c from jsonb_array_elements(public.client_visits(p_consultant)->'consultants') c),
  extra as (
    select 1 ord, jsonb_build_object('kind', 'cleanup', 'item_key', 'cleanup:'||current_date,
           'action', (select count(*) from stale)||case when (select count(*) from stale) = 1 then ' stage looks' else ' stages look' end||' out of date (offers over 21 days, interview requests unbooked over 14): update or close them in RecruitCRM',
           'who', (select string_agg(who, ', ' order by age desc) from (select who, age from stale order by age desc limit 5) t)
                  || case when (select count(*) from stale) > 5 then ', …' else '' end) j
    where exists (select 1 from stale)
    union all
    select 2, jsonb_build_object('kind', 'meetings', 'item_key', 'meetings:'||current_date,
           'action', n||case when n = 1 then ' meeting' else ' meetings' end||' this quarter '||case when n = 1 then 'has' else 'have' end||' no type, so client visits can''t be counted: ask Claude to review my meetings',
           'who', null)
    from untyped where n > 0 and extract(isodow from current_date) in (1, 4)
    union all
    select 3, jsonb_build_object('kind', 'client_visits', 'item_key', 'visits:'||to_char(current_date, 'IYYY-IW'),
           'action', 'Client visits this quarter: '||(cv.c->>'visits_done')||' done, '||(cv.c->>'visits_booked')||' booked, of 2. Ask Claude to plan a visit',
           'who', (select string_agg(s->>'client', ', ') from (select s from jsonb_array_elements(cv.c->'suggestions') s limit 3) t))
    from cv
    where extract(isodow from current_date) = 1
      and (cv.c->>'visits_done')::int + (cv.c->>'visits_booked')::int < 2
  )
  select jsonb_build_object(
    'consultant', (select name from me),
    'for_date', current_date,
    'total', (select count(*) from allrows),
    'by_kind', (select coalesce(jsonb_object_agg(kind, n), '{}'::jsonb) from (select kind, count(*) n from allrows group by kind) k),
    'stale_stages', (select count(*) from stale),
    'items', coalesce((select jsonb_agg(jsonb_build_object('kind', kind, 'item_key', item_key, 'action', action, 'who', who, 'job', job,
                         'client', client, 'candidate_slug', candidate_slug, 'job_slug', job_slug)
                         order by rank, age desc nulls last, who) from capped), '[]'::jsonb)
      || coalesce((select jsonb_agg(j order by ord) from extra), '[]'::jsonb));
$function$;

-- The quarter's meetings, refreshed daily before the briefs and the queue.
create or replace function public.meetings_quarter_refresh()
returns void language plpgsql security definer set search_path to 'public'
as $function$
declare hdrs jsonb;
begin
  select jsonb_build_object('Authorization', 'Bearer ' || value, 'Content-Type', 'application/json')
    into hdrs from app_settings where key = 'cron_bearer';
  if hdrs is null then
    raise warning 'meetings_quarter_refresh: app_settings.cron_bearer not set, skipped';
    return;
  end if;
  perform net.http_post(
    url := 'https://kzcmssldvtjnbwwunuwm.supabase.co/functions/v1/recruitcrm-sync?mode=meetings_quarter',
    headers := hdrs, body := '{}'::jsonb, timeout_milliseconds := 55000);
end;
$function$;
revoke execute on function public.meetings_quarter_refresh() from public, anon, authenticated;

select cron.schedule('meetings-quarter-refresh', '10 6 * * *', $$select public.meetings_quarter_refresh();$$);
insert into cron_manifest (jobname, schedule, note, required)
values ('meetings-quarter-refresh', '10 6 * * *', 'meetings since the quarter start, for client visits', true)
on conflict (jobname) do update set schedule = excluded.schedule, note = excluded.note, required = excluded.required;

-- Week Ahead brief: client visits this quarter per consultant, before the cold roles. Guarded.
do $do$
declare
  def text := pg_get_functiondef('public.post_digest(text)'::regprocedure);
  anchor text := $a$    body := public.slack_cold_roles(d->'cold_roles', 10);$a$;
  addition text := $b$    -- 0118: client visits this quarter per consultant, against the minimum of 2.
    vz := public.client_visits();
    if jsonb_array_length(vz->'consultants') > 0 then
      select string_agg(case when (x->>'visits_done')::int + (x->>'visits_booked')::int < 2 then ':warning: ' else '• ' end||
               public.slack_escape(x->>'consultant')||' — '||(x->>'visits_done')||' done, '||(x->>'visits_booked')||' booked'||
               case when (x->>'untyped_meetings')::int > 0 then ' · '||(x->>'untyped_meetings')||' untyped' else '' end, E'\n')
        into body from (select x from jsonb_array_elements(vz->'consultants') x limit 15) s;
      blocks := blocks || public.slack_section('*Client visits this quarter* (minimum 2 each)'||E'\n'||body||
        E'\n_Only meetings typed Client Meeting count. "Review my meetings" in Claude types the rest; "plan a visit" suggests who and drafts the request._');
    end if;

$b$;
begin
  if position('public.client_visits()' in def) > 0 then
    return;   -- already applied
  end if;
  if (length(def) - length(replace(def, anchor, ''))) / length(anchor) <> 1 then
    raise exception '0118: post_digest weekly anchor not found exactly once; the Week Ahead brief has changed since 0113';
  end if;
  def := replace(def, anchor, addition || anchor);
  def := replace(def, 'n int; dd jsonb; uc jsonb; tr jsonb;', 'n int; dd jsonb; uc jsonb; tr jsonb; vz jsonb;');
  if position('vz jsonb;' in def) = 0 then
    raise exception '0118: post_digest declare block not found';
  end if;
  execute def;
end;
$do$;
