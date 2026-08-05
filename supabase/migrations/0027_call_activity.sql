-- 0027_call_activity.sql
-- Telephony activity (Devyce → RecruitCRM → mirror). Devyce logs calls into RecruitCRM;
-- we pull them from GET /v1/call-logs into call_activity. This adds the LEADING-INDICATOR
-- layer the platform lacked: the calls that drive CVs → interviews → placements.
--
-- Attribution here is the CALLER (created_by) — it's that consultant's own activity
-- (unlike the funnel, which credits the job owner). PII (phone number, call notes) is
-- deliberately NOT mirrored — only activity metadata.
--
-- custom_call_type labels (e.g. 'Contact - Prospect (BD)', 'Contact - Client',
-- 'Interview Feedback') double as a BD/activity taxonomy.

create table if not exists public.call_activity (
  recruitcrm_id            bigint primary key,
  call_type                text,          -- CALL_OUTGOING | CALL_INCOMING
  custom_call_type         text,          -- label, e.g. 'Contact - Prospect (BD)'
  call_started_on          timestamptz,
  call_date                date,
  duration_seconds         integer,
  connected                boolean,       -- duration_seconds > 0
  consultant_recruitcrm_id bigint,        -- created_by = the caller
  consultant               text,          -- resolved name (denormalised at sync)
  related_to               text,          -- slug of the linked record
  related_to_type          text,          -- candidate | contact | company
  created_at               timestamptz not null default now()
);
alter table public.call_activity enable row level security;
drop policy if exists call_activity_read_auth on public.call_activity;
create policy call_activity_read_auth on public.call_activity for select to authenticated using (true);
create index if not exists call_activity_date_idx on public.call_activity (call_date);
create index if not exists call_activity_consultant_idx on public.call_activity (consultant_recruitcrm_id);

-- Call-activity report, attributed to the caller. Optional consultant/team/type filters.
create or replace function public.call_activity_report(
  p_from date default '2026-01-01', p_to date default '2100-01-01',
  p_consultant text default null, p_team text default null)
returns jsonb language sql stable security definer set search_path to 'public' as $function$
  with ca as (
    select a.*, co.name cons_name, co.team
    from call_activity a
    left join consultants co on co.recruitcrm_id = a.consultant_recruitcrm_id and co.deleted_at is null
    where a.call_date >= p_from and a.call_date < p_to
      and (p_consultant is null or co.name ilike '%'||p_consultant||'%')
      and (p_team is null or co.team = p_team)
  )
  select jsonb_build_object(
    'window', jsonb_build_object('from', p_from, 'to', p_to),
    'definition', 'Call activity from RecruitCRM call-logs (logged via Devyce), attributed to the caller (created_by). duration in seconds; connected = duration > 0. Talk time reported in minutes.',
    'totals', (select jsonb_build_object(
        'calls', count(*),
        'connected', count(*) filter (where connected),
        'connect_rate', round(count(*) filter (where connected)::numeric / nullif(count(*),0), 3),
        'talk_minutes', round(coalesce(sum(duration_seconds),0)/60.0, 1),
        'outgoing', count(*) filter (where call_type='CALL_OUTGOING'),
        'incoming', count(*) filter (where call_type='CALL_INCOMING')) from ca),
    'by_consultant', (select coalesce(jsonb_agg(jsonb_build_object(
        'name', coalesce(cons_name,'(unknown user '||consultant_recruitcrm_id||')'),
        'calls', n, 'connected', conn, 'connect_rate', round(conn::numeric/nullif(n,0),3),
        'talk_minutes', round(secs/60.0,1)) order by n desc), '[]'::jsonb)
      from (select consultant_recruitcrm_id, cons_name, count(*) n,
              count(*) filter (where connected) conn, coalesce(sum(duration_seconds),0) secs
            from ca group by consultant_recruitcrm_id, cons_name) c),
    'by_category', (select coalesce(jsonb_agg(jsonb_build_object('category', coalesce(custom_call_type,'(uncategorised)'), 'calls', n) order by n desc), '[]'::jsonb)
      from (select custom_call_type, count(*) n from ca group by custom_call_type) t)
  );
$function$;

revoke all on function public.call_activity_report(date,date,text,text) from public, anon, authenticated;
grant execute on function public.call_activity_report(date,date,text,text) to service_role;
