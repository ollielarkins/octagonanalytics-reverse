-- 0110_meetings_diary_digest.sql
-- Priority 1 (Bhav, 20/10/2026), finished 26/10/2026: prep the day before an interview, chase
-- feedback the day after, without the recruiter having to ask. The schedule tool (3.72.0) reads
-- RecruitCRM meetings live, but only when someone calls it, and it had no calls in five days. The
-- morning brief is built in SQL from the mirror, so the meetings diary is mirrored here: a rolling
-- window kept fresh by recruitcrm-sync's incremental run (every 15 minutes), per active consultant.
--
-- Deploy order: this migration, then recruitcrm-sync (until it is deployed the table stays empty and
-- the brief simply shows no diary section, and sync_health warns on 'meetings').

create table if not exists public.meetings (
  recruitcrm_id       bigint primary key,
  title               text,
  meeting_type        text,
  owner_recruitcrm_id bigint,
  start_at            timestamptz,
  end_at              timestamptz,
  related_to          text,
  related_to_type     text,
  candidate_slug      text,
  job_slug            text,
  synced_at           timestamptz not null default now(),
  deleted_at          timestamptz
);
create index if not exists meetings_owner_start_idx on public.meetings (owner_recruitcrm_id, start_at) where deleted_at is null;
-- Service role only, like the rest of the mirror: meeting titles name candidates.
alter table public.meetings enable row level security;
revoke all on table public.meetings from anon, authenticated;

-- sync_health: 'meetings' joins the live feeds, on the same cadence as notes.
create or replace function public.sync_health()
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  with cfg(entity, category, warn_min, crit_min, strict_status) as (
    values
      ('candidates','live',20,45,true),
      ('clients','live',20,45,true),
      ('consultants','live',20,45,true),
      ('jobs','live',20,45,true),
      ('calls','live',20,45,true),
      ('deals','live',20,45,true),
      ('history_recent','live',25,60,false),
      ('notes','live',25,60,false),
      ('meetings','live',25,60,false),
      ('offlimit','reconcile',120,240,false),
      ('reconcile:clients','reconcile',120,240,false),
      ('reconcile:jobs','reconcile',120,240,false),
      ('reconcile:deals','reconcile',120,240,false),
      ('backfill:candidates','reconcile',840,1080,false)
  ),
  good(status) as (values ('ok'),('caught_up'),('complete'),('resume_next_page')),
  ev as (
    select c.entity, c.category, c.warn_min, c.crit_min, c.strict_status,
           s.last_run_at, s.last_status,
           round(extract(epoch from (now()-s.last_run_at))/60)::int as mins
    from cfg c left join sync_state s on s.entity = c.entity
  ),
  cls as (
    select entity, category, last_run_at, last_status, mins,
      case
        when last_run_at is null then 'critical'
        -- An error only goes critical once the next scheduled run has also failed to succeed.
        when strict_status and last_status is not null
             and last_status not in (select status from good)
             and mins >= warn_min then 'critical'
        when mins >= crit_min then 'critical'
        -- A single failed run that has not yet had a chance to retry: warn, no Slack alert.
        when strict_status and last_status is not null
             and last_status not in (select status from good) then 'warn'
        when mins >= warn_min then 'warn'
        else 'ok'
      end as status,
      case
        when last_run_at is null then 'no sync run on record'
        when strict_status and last_status is not null
             and last_status not in (select status from good)
             and mins >= warn_min then 'error status: '||last_status
        when mins >= crit_min then 'stale: '||mins||' min since last run'
        when strict_status and last_status is not null
             and last_status not in (select status from good) then 'error status (retrying): '||last_status
        when mins >= warn_min then 'slowing: '||mins||' min since last run'
        else 'fresh'
      end as reason
    from ev
  )
  select jsonb_build_object(
    'generated_at', now(),
    'overall', (select case
                  when bool_or(status='critical') then 'critical'
                  when bool_or(status='warn') then 'warn'
                  else 'ok' end from cls),
    'entities', (select jsonb_agg(jsonb_build_object(
        'entity', entity, 'category', category, 'last_run_at', last_run_at,
        'minutes_stale', mins, 'last_status', last_status,
        'status', status, 'reason', reason)
        order by (status='critical') desc, (status='warn') desc, entity) from cls)
  );
$function$;

-- diary_digest(): per consultant, the interviews on the next working day (prep) and the interviews
-- already held with nothing logged since (feedback due), from the mirrored diary. Same rules as the
-- schedule tool: an interview is a meeting typed "Candidate - ... Interview"; feedback is due once
-- the interview has ended plus 2 hours, with no feedback call, candidate note or stage move since it
-- started; looks back 4 days so Monday's brief covers Thursday and Friday.
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
      and start_at >= now() - interval '4 days'
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
                    'job', x.job, 'client', x.client, 'type', x.meeting_type) order by x.local_start), '[]'::jsonb)
                 from prep x where x.consultant = p.consultant),
        'feedback_due', (select coalesce(jsonb_agg(jsonb_build_object(
                    'held', to_char(x.local_start, 'Dy DD/MM HH24:MI'), 'candidate', coalesce(x.candidate, x.title),
                    'job', x.job, 'client', x.client) order by x.local_start), '[]'::jsonb)
                 from fb x where x.consultant = p.consultant))
      order by p.consultant) from people p), '[]'::jsonb)
  );
$function$;
revoke execute on function public.diary_digest() from public, anon, authenticated;
grant execute on function public.diary_digest() to service_role;

-- post_digest('morning'): a "From the RecruitCRM diary" section, one line per consultant, placed
-- before the previous-working-day stats. Guarded: if the anchor has moved, fail loudly rather than
-- silently leave the brief without it (CONTRIBUTING, 0083).
do $do$
declare
  def text := pg_get_functiondef('public.post_digest(text)'::regprocedure);
  anchor text := $a$    blocks := blocks || public.slack_section(
      '*Previous working day* ('$a$;
  addition text := $b$    -- 0110: the RecruitCRM diary, per consultant: interviews to prep for on the next working
    -- day, and interviews held with nothing logged since.
    dd := public.diary_digest();
    if jsonb_array_length(dd->'by_consultant') > 0 then
      select string_agg('• *'||public.slack_escape(x->>'consultant')||'* — '||
               case when jsonb_array_length(x->'prep') > 0 then
                 'prep '||jsonb_array_length(x->'prep')||' ('||
                 (select string_agg(public.slack_escape(p->>'candidate')||' '||(p->>'time'), ', ')
                    from (select p from jsonb_array_elements(x->'prep') p limit 4) s)||
                 case when jsonb_array_length(x->'prep') > 4 then ', …' else '' end||')'
               else '' end||
               case when jsonb_array_length(x->'prep') > 0 and jsonb_array_length(x->'feedback_due') > 0 then ' · ' else '' end||
               case when jsonb_array_length(x->'feedback_due') > 0 then
                 'feedback due '||jsonb_array_length(x->'feedback_due')||' ('||
                 (select string_agg(public.slack_escape(f->>'candidate'), ', ')
                    from (select f from jsonb_array_elements(x->'feedback_due') f limit 4) s)||
                 case when jsonb_array_length(x->'feedback_due') > 4 then ', …' else '' end||')'
               else '' end, E'\n')
        into body from (select x from jsonb_array_elements(dd->'by_consultant') x limit 15) s;
      blocks := blocks || public.slack_section('*From the RecruitCRM diary* — prep for '||
        to_char((dd->>'prep_day')::date, 'Dy DD/MM')||', feedback due'||E'\n'||body||
        E'\n_Only interviews logged as meetings in RecruitCRM. Feedback due = nothing logged since the interview, not proof it was never given._');
    end if;

$b$;
begin
  if position(anchor in def) = 0 then
    raise exception '0110: post_digest anchor not found; the morning brief has changed since 26/10/2026';
  end if;
  if position('public.diary_digest()' in def) > 0 then
    return;   -- already applied
  end if;
  def := replace(def, anchor, addition || anchor);
  def := replace(def, 'body text; health jsonb; healthline text; n int;', 'body text; health jsonb; healthline text; n int; dd jsonb;');
  if position('dd jsonb;' in def) = 0 then
    raise exception '0110: post_digest declare block not found';
  end if;
  execute def;
end;
$do$;
