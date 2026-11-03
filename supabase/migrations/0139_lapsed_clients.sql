-- 0139_lapsed_clients.sql
-- Lapsed clients: companies we have placed with before that have no Open or On Hold job and have not
-- given us a new job in p_months (default 6). They already know us and have paid us, so they are the
-- warmest BD calls there are. Found in the command gap review (03/11/2026): 81 such clients and no
-- command surfaced them.
--
-- Per client: placements and last placement, lifetime Won deal value (billing = Won deal value),
-- last job date and its owner (the desk the client belongs to; leavers tagged), and the last logged
-- touch: company notes, calls logged against the company, and visits. Calls logged against a contact
-- cannot be tied to a company here (contacts are not mirrored), so last_touch can be older than the
-- real last call: the result says so. Blocklisted and Do not contact companies are left out and
-- counted. Ranked by lifetime Won value, then placements.

create or replace function public.lapsed_clients(p_months int default 6, p_consultant text default null, p_limit int default 50)
returns jsonb
language sql
stable security definer
set search_path to 'public'
as $function$
  with cut as (
    select ((now() at time zone 'Europe/London')::date - make_interval(months => greatest(coalesce(p_months, 6), 1)))::date d
  ),
  placed as (
    select j.client_id, count(*) placements, max(e.event_date) last_placed
    from candidate_stage_events e join jobs j on j.slug = e.job_slug and j.deleted_at is null
    where e.stage_metric = 'placed' and j.client_id is not null
    group by 1
  ),
  client_jobs as (
    select client_id, max(created_date)::date last_job, count(*) jobs_total,
      count(*) filter (where status in ('Open', 'On Hold')) live_jobs
    from jobs where deleted_at is null and client_id is not null
    group by 1
  ),
  last_owner as (
    select distinct on (client_id) client_id, consultant_id
    from jobs where deleted_at is null and client_id is not null
    order by client_id, created_date desc nulls last
  ),
  won as (
    select company_slug, count(*) won_deals, sum(deal_value) won_value, max(close_date) last_won
    from deals where deleted_at is null and deal_stage = 'Won'
    group by 1
  ),
  touch as (
    select related_to slug, max(created_on)::date t from notes where related_to_type = 'company' group by 1
    union all
    select related_to, max(call_started_on)::date from call_activity where related_to_type = 'company' group by 1
    union all
    select company_slug, max(start_at)::date from meetings where deleted_at is null and company_slug is not null group by 1
  ),
  last_touch as (select slug, max(t) t from touch group by 1),
  lapsed as (
    select c.company_slug, c.company_name, c.company_status, p.placements, p.last_placed, cj.last_job, cj.jobs_total,
      coalesce(w.won_deals, 0) won_deals, coalesce(w.won_value, 0) won_value, w.last_won,
      co.name consultant, (co.id is not null and coalesce(co.active, true) and co.deleted_at is null) consultant_active, lt.t last_touch,
      coalesce(c.company_status, '') in ('Blocklisted', 'Do not contact') barred
    from clients c
    join placed p on p.client_id = c.id
    join client_jobs cj on cj.client_id = c.id
    left join last_owner lo on lo.client_id = c.id
    left join consultants co on co.id = lo.consultant_id
    left join won w on w.company_slug = c.company_slug
    left join last_touch lt on lt.slug = c.company_slug, cut
    where c.deleted_at is null and cj.live_jobs = 0 and cj.last_job < cut.d
  ),
  scoped as (select * from lapsed where p_consultant is null or consultant ilike '%' || p_consultant || '%'),
  eligible as (select * from scoped where not barred),
  top as (select * from eligible order by won_value desc, placements desc, last_job desc limit greatest(coalesce(p_limit, 50), 1))
  select jsonb_build_object(
    'months', greatest(coalesce(p_months, 6), 1), 'no_new_job_since', (select d from cut),
    'definition', 'Companies we have placed with before that have no Open or On Hold job and no new job since no_new_job_since. Owned by whoever owned their most recent job. won_value is lifetime Won deal value. last_touch is the latest company note, call logged against the company, or visit; calls logged against a contact are not included, so the real last contact can be more recent. Blocklisted and Do not contact companies are left out.',
    'counts', jsonb_build_object('lapsed', (select count(*) from scoped), 'barred_excluded', (select count(*) from scoped where barred),
      'available', (select count(*) from eligible), 'shown', (select count(*) from top),
      'won_value_lapsed', (select coalesce(sum(won_value), 0) from eligible)),
    'by_consultant', coalesce((select jsonb_agg(jsonb_build_object('consultant', coalesce(consultant, 'No owner'), 'left', not active, 'clients', n, 'won_value', v) order by v desc)
      from (select consultant, bool_and(consultant_active) active, count(*) n, sum(won_value) v from eligible group by consultant) s), '[]'::jsonb),
    'clients', coalesce((select jsonb_agg(jsonb_build_object(
        'client', company_name, 'company_slug', company_slug, 'status', company_status,
        'placements', placements, 'last_placed', last_placed, 'won_deals', won_deals, 'won_value', won_value, 'last_won', last_won,
        'jobs_total', jobs_total, 'last_job', last_job,
        'months_since_last_job', (extract(year from age((now() at time zone 'Europe/London')::date, last_job)) * 12
                                  + extract(month from age((now() at time zone 'Europe/London')::date, last_job)))::int,
        'last_touch', last_touch, 'touched_since_last_job', coalesce(last_touch > last_job, false),
        'consultant', consultant, 'consultant_left', not consultant_active
      ) order by won_value desc, placements desc, last_job desc) from top), '[]'::jsonb)
  );
$function$;
revoke execute on function public.lapsed_clients(int, text, int) from public, anon, authenticated;
