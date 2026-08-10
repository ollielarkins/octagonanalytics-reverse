-- 0045_client_report_corrections.sql
-- Two corrections to client_report():
--
-- 1. cv_to_placed_pct was round(placed/cv, 3) — a FRACTION under a _pct name. Thermoteknix came
--    back as 0.007 when the real rate is 0.7%, so anything reading the field at face value
--    understated conversion by 100x. Now a true percentage to 1dp, matching its name and the
--    house convention of naming the ratio ("CV→placed 2.4%").
--
-- 2. The embedded definition string still claimed "~40% of jobs have an unresolved client link
--    (archived companies)". That was never archived companies — it was a 1,000-row PostgREST cap on
--    the sync's client lookup (fixed 10/08/2026). After the fix, 9 of 5,975 jobs are unresolved
--    (0.2%) and none of them are open.
create or replace function public.client_report(p_from date default '2026-01-01'::date, p_to date default '2100-01-01'::date, p_client text default null::text, p_limit integer default 20)
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
    'definition','Per-client activity within [from,to), from candidate_stage_events joined via the owning job. cv_to_placed_pct is a percentage to 1dp. Client attribution now covers ~99.8% of jobs; a handful with no company on the record are omitted.',
    'clients', (select coalesce(jsonb_agg(jsonb_build_object(
        'client',client,'cv_sent',cv,'first_interview',fi,'placed',pl,
        'open_jobs',open_jobs,'total_jobs',total_jobs,
        'cv_to_placed_pct',round(100*pl::numeric/nullif(cv,0),1)) order by cv desc), '[]'::jsonb) from top)
  );
$function$;

revoke all on function public.client_report(date,date,text,integer) from public, anon, authenticated;
grant execute on function public.client_report(date,date,text,integer) to service_role;
