-- 0016_mcp_read_functions.sql
-- Additional read-side reporting functions behind new MCP tools (product coverage).
-- All owner-attributed (jobs.consultant_id, per D9), 2026-default window, soft-deletes
-- excluded, service_role-only (called by the octagon-mcp edge function). Every metric
-- lives here in the semantic layer so dashboards and Claude can never disagree.
--
-- IMPORTANT data realities baked in:
--   * The placements table is EMPTY and no fee source exists in the mirror, so
--     placements_report uses the event-stream 'placed' count (D4) and reports revenue
--     from Won deals (D5) — it never fabricates fees.
--   * ~40% of jobs have an unresolved client link (archived companies); client_report
--     says so rather than silently undercounting.

-- ---------------------------------------------------------------------------
-- client_report — per-client activity in a window
-- ---------------------------------------------------------------------------
create or replace function public.client_report(
  p_from date default '2026-01-01', p_to date default '2100-01-01',
  p_client text default null, p_limit int default 20)
returns jsonb language sql stable security definer set search_path to 'public' as $function$
  with ev as (
    select cl.company_name as client, cl.id cid, e.stage_metric
    from candidate_stage_events e
    join jobs j on e.job_slug = j.slug and j.deleted_at is null
    join clients cl on j.client_id = cl.id and cl.deleted_at is null
    where e.event_date >= p_from and e.event_date < p_to
      and (p_client is null or cl.company_name ilike '%'||p_client||'%')
  ),
  agg as (
    select client, cid,
      count(*) filter (where stage_metric='cv_sent') cv,
      count(*) filter (where stage_metric='first_interview') fi,
      count(*) filter (where stage_metric='placed') pl
    from ev group by client, cid
  ),
  oj as (
    select cl.id cid,
      count(*) filter (where j.status='Open') open_jobs, count(*) total_jobs
    from jobs j join clients cl on j.client_id = cl.id and cl.deleted_at is null
    where j.deleted_at is null group by cl.id
  ),
  top as (
    select a.client, a.cv, a.fi, a.pl,
           coalesce(o.open_jobs,0) open_jobs, coalesce(o.total_jobs,0) total_jobs
    from agg a left join oj o using(cid)
    order by a.cv desc limit p_limit
  )
  select jsonb_build_object(
    'window', jsonb_build_object('from',p_from,'to',p_to),
    'definition','Per-client activity within [from,to), from candidate_stage_events joined via the owning job. ~40% of jobs have an unresolved client link (archived companies) and are omitted from client attribution.',
    'clients', (select coalesce(jsonb_agg(jsonb_build_object(
        'client',client,'cv_sent',cv,'first_interview',fi,'placed',pl,
        'open_jobs',open_jobs,'total_jobs',total_jobs,
        'cv_to_placed_pct',round(pl::numeric/nullif(cv,0),3)) order by cv desc), '[]'::jsonb) from top)
  );
$function$;

-- ---------------------------------------------------------------------------
-- time_to_fill — days from job open to first 'placed' event, for jobs placed in window
-- ---------------------------------------------------------------------------
create or replace function public.time_to_fill(
  p_from date default '2026-01-01', p_to date default '2100-01-01',
  p_consultant text default null, p_team text default null)
returns jsonb language sql stable security definer set search_path to 'public' as $function$
  with placed as (
    select j.slug, co.name consultant, co.team,
           min(e.event_date) placed_date, j.created_date::date created
    from candidate_stage_events e
    join jobs j on e.job_slug = j.slug and j.deleted_at is null
    join consultants co on j.consultant_id = co.id and co.deleted_at is null
    where e.stage_metric='placed' and e.event_date >= p_from and e.event_date < p_to
      and (p_consultant is null or co.name ilike '%'||p_consultant||'%')
      and (p_team is null or co.team = p_team)
    group by j.slug, co.name, co.team, j.created_date
  ),
  d as (
    select consultant, (placed_date - created) days
    from placed where created is not null and placed_date >= created
  )
  select jsonb_build_object(
    'window', jsonb_build_object('from',p_from,'to',p_to),
    'definition','Days from job created_date to the first placed event, for jobs placed within [from,to). Owner-attributed.',
    'placements_measured', (select count(*) from d),
    'days', (select jsonb_build_object(
       'avg', round(avg(days),1), 'median', percentile_cont(0.5) within group (order by days),
       'min', min(days), 'max', max(days)) from d),
    'by_consultant', (select coalesce(jsonb_agg(jsonb_build_object(
       'name',consultant,'placements',n,'avg_days',round(avg_days,1),'median_days',median_days)
       order by n desc), '[]'::jsonb) from (
       select consultant, count(*) n, avg(days) avg_days,
              percentile_cont(0.5) within group (order by days) median_days
       from d group by consultant) c)
  );
$function$;

-- ---------------------------------------------------------------------------
-- cold_jobs — OPEN jobs with no candidate activity in the last p_days
-- ---------------------------------------------------------------------------
create or replace function public.cold_jobs(
  p_days int default 14, p_consultant text default null, p_limit int default 50)
returns jsonb language sql stable security definer set search_path to 'public' as $function$
  with open_jobs as (
    select j.slug, j.title, j.created_date::date created, co.name consultant, cl.company_name client
    from jobs j
    join consultants co on j.consultant_id = co.id and co.deleted_at is null
    left join clients cl on j.client_id = cl.id and cl.deleted_at is null
    where j.deleted_at is null and j.status='Open'
      and (p_consultant is null or co.name ilike '%'||p_consultant||'%')
  ),
  last_act as (
    select job_slug, max(event_date) last_date
    from candidate_stage_events group by job_slug
  ),
  cold as (
    select o.title, o.client, o.consultant, o.created, l.last_date,
           (current_date - l.last_date) days_since
    from open_jobs o left join last_act l on l.job_slug = o.slug
    where l.last_date is null or l.last_date < current_date - make_interval(days => p_days)
    order by coalesce(l.last_date, date '1900-01-01') asc
    limit p_limit
  )
  select jsonb_build_object(
    'threshold_days', p_days,
    'definition','OPEN jobs whose most recent candidate_stage_event is older than threshold_days (or that have none). Job titles/clients only — no candidate PII.',
    'cold_count', (select count(*) from cold),
    'jobs', (select coalesce(jsonb_agg(jsonb_build_object(
       'job_title',title,'client',client,'consultant',consultant,'opened',created,
       'last_activity', last_date, 'days_since_activity', days_since)
       order by coalesce(last_date, date '1900-01-01') asc), '[]'::jsonb) from cold)
  );
$function$;

-- ---------------------------------------------------------------------------
-- placements_report — placed events (D4) by consultant/client + Won revenue (D5)
-- ---------------------------------------------------------------------------
create or replace function public.placements_report(
  p_from date default '2026-01-01', p_to date default '2100-01-01',
  p_consultant text default null, p_team text default null)
returns jsonb language sql stable security definer set search_path to 'public' as $function$
  with pe as (
    select co.name consultant, cl.company_name client
    from candidate_stage_events e
    join jobs j on e.job_slug = j.slug and j.deleted_at is null
    join consultants co on j.consultant_id = co.id and co.deleted_at is null
    left join clients cl on j.client_id = cl.id and cl.deleted_at is null
    where e.stage_metric='placed' and e.event_date >= p_from and e.event_date < p_to
      and (p_consultant is null or co.name ilike '%'||p_consultant||'%')
      and (p_team is null or co.team = p_team)
  )
  select jsonb_build_object(
    'window', jsonb_build_object('from',p_from,'to',p_to),
    'definition','Placements = event-stream ''placed'' events (the placements table is empty and fee data is not mirrored, so no fees). Revenue = sum of Won deal_value by close_date in the window.',
    'placed_total', (select count(*) from pe),
    'won_revenue', (select coalesce(sum(deal_value),0) from deals
                    where deal_stage='Won' and close_date >= p_from and close_date < p_to),
    'by_consultant', (select coalesce(jsonb_agg(jsonb_build_object('name',consultant,'placed',n)
        order by n desc), '[]'::jsonb) from (select consultant, count(*) n from pe group by consultant) c),
    'by_client', (select coalesce(jsonb_agg(jsonb_build_object('client',client,'placed',n)
        order by n desc), '[]'::jsonb) from (select client, count(*) n from pe where client is not null group by client) c)
  );
$function$;

-- ---------------------------------------------------------------------------
-- consultant_leaderboard — ranked consultants by a chosen metric
-- ---------------------------------------------------------------------------
create or replace function public.consultant_leaderboard(
  p_from date default '2026-01-01', p_to date default '2100-01-01',
  p_metric text default 'placed', p_limit int default 20)
returns jsonb language sql stable security definer set search_path to 'public' as $function$
  with per as (
    select co.name consultant,
      count(*) filter (where e.stage_metric='cv_sent') cv,
      count(*) filter (where e.stage_metric='first_interview') fi,
      count(*) filter (where e.stage_metric='placed') pl
    from candidate_stage_events e
    join jobs j on e.job_slug = j.slug and j.deleted_at is null
    join consultants co on j.consultant_id = co.id and co.deleted_at is null
    where e.event_date >= p_from and e.event_date < p_to
    group by co.name
  ),
  ranked as (
    select consultant, cv, fi, pl,
      case when p_metric='cv_sent' then cv when p_metric='first_interview' then fi else pl end as sortval
    from per order by sortval desc, cv desc limit p_limit
  )
  select jsonb_build_object(
    'window', jsonb_build_object('from',p_from,'to',p_to),
    'ranked_by', p_metric,
    'definition','Consultants ranked by the chosen metric (placed|cv_sent|first_interview), owner-attributed, within [from,to).',
    'leaderboard', (select coalesce(jsonb_agg(jsonb_build_object(
       'name',consultant,'cv_sent',cv,'first_interview',fi,'placed',pl,
       'cv_to_placed_pct',round(pl::numeric/nullif(cv,0),3)) order by sortval desc, cv desc), '[]'::jsonb) from ranked)
  );
$function$;

revoke all on function public.client_report(date,date,text,int)          from public, anon, authenticated;
revoke all on function public.time_to_fill(date,date,text,text)          from public, anon, authenticated;
revoke all on function public.cold_jobs(int,text,int)                    from public, anon, authenticated;
revoke all on function public.placements_report(date,date,text,text)     from public, anon, authenticated;
revoke all on function public.consultant_leaderboard(date,date,text,int) from public, anon, authenticated;
grant execute on function public.client_report(date,date,text,int)          to service_role;
grant execute on function public.time_to_fill(date,date,text,text)          to service_role;
grant execute on function public.cold_jobs(int,text,int)                    to service_role;
grant execute on function public.placements_report(date,date,text,text)     to service_role;
grant execute on function public.consultant_leaderboard(date,date,text,int) to service_role;
