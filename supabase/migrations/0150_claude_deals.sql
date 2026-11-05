-- 0150_claude_deals.sql
-- What Claude has contributed to deals (05/11/2026). Asked "how much has Claude made", the connector
-- said it could not be traced; it can. audit_log keeps the candidate and job of every change made
-- through Claude, and from now on claude_suggestions keeps who /match put in front of whom.
--
-- Two kinds of credit, never mixed:
--   sourced:  Claude found or placed the candidate on the job. The candidate was added to the job
--             through Claude (assign_candidate), or /match suggested them to that consultant and the
--             same consultant sent their CV within 60 days (to that job, or to any job when the
--             search had no job). Pairs where the candidate was already on the job beforehand are
--             not sourced.
--   recorded: Claude only did the admin, a stage move made through Claude on a pair it did not source.
-- Each pair's furthest stage, and the deal on its job: Won (billing) when the candidate was placed,
-- Offered (pipeline) when they reached Offered. When a job has several deals, the one naming the
-- candidate wins, else the job's only deal of that stage; otherwise no value is claimed.

create table if not exists public.claude_suggestions (
  id bigint generated always as identity primary key,
  consultant_recruitcrm_id bigint,
  candidate_slug text not null,
  job_slug text,
  source text not null default 'match_candidates',
  suggested_at timestamptz not null default now()
);
create index if not exists claude_suggestions_cand_idx on public.claude_suggestions (candidate_slug, suggested_at);
alter table public.claude_suggestions enable row level security;
revoke all on table public.claude_suggestions from anon, authenticated;

create or replace function public.claude_deals(p_from date default '2026-08-01', p_to date default null, p_consultant text default null)
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  with w as (select coalesce(p_from, date '2026-08-01') f, coalesce(p_to, 'infinity'::date) t),
  rank(metric, r) as (values ('cv_sent',1),('interview_request',2),('first_interview',3),('second_interview',4),
                             ('third_interview',5),('offered',6),('placed',7)),
  assigned as (
    select a.entity_id cand, a.after->>'job_slug' job, a.actor::bigint cid, min(a.created_at) at, 'added to the job through Claude' how
    from audit_log a, w
    where a.action = 'assign_candidate' and a.after ? 'job_slug' and a.actor ~ '^[0-9]+$' and a.actor <> '0'
      and a.created_at >= w.f and a.created_at < w.t
    group by 1, 2, 3
  ),
  suggested as (
    select s.candidate_slug cand, e.job_slug job, s.consultant_recruitcrm_id cid, min(s.suggested_at) at, 'suggested by /match, CV sent' how
    from claude_suggestions s
    join candidate_stage_events e on e.candidate_slug = s.candidate_slug and e.stage_metric = 'cv_sent'
      and e.consultant_id = s.consultant_recruitcrm_id
      and e.event_timestamp >= (s.suggested_at at time zone 'UTC') and e.event_timestamp < (s.suggested_at at time zone 'UTC') + interval '60 days'
      and (s.job_slug is null or e.job_slug = s.job_slug), w
    where s.suggested_at >= w.f and s.suggested_at < w.t
    group by 1, 2, 3
  ),
  src as (
    select distinct on (cand, job) cand, job, cid, at, how
    from (select * from assigned union all select * from suggested) x
    where job is not null
      -- Already in play on that job before Claude touched it: not sourced.
      and not exists (select 1 from candidate_stage_events e where e.candidate_slug = x.cand and e.job_slug = x.job
                        and e.event_timestamp < (x.at at time zone 'UTC') - interval '1 day')
    order by cand, job, at
  ),
  recorded as (
    select a.entity_id cand, a.after->>'job_slug' job, a.actor::bigint cid, min(a.created_at) at
    from audit_log a, w
    where a.action = 'update_hiring_stage' and a.after ? 'job_slug' and a.actor ~ '^[0-9]+$'
      and a.created_at >= w.f and a.created_at < w.t
      and not exists (select 1 from src where src.cand = a.entity_id and src.job = a.after->>'job_slug')
    group by 1, 2, 3
  ),
  pairs as (
    select 'sourced' kind, cand, job, cid, at, how from src
    union all select 'recorded', cand, job, cid, at, 'stage moved through Claude' from recorded
  ),
  furthest as (
    select p.*, (select e.stage_metric from candidate_stage_events e join rank r on r.metric = e.stage_metric
                  where e.candidate_slug = p.cand and e.job_slug = p.job order by r.r desc limit 1) stage,
           (select max(e.candidate_name) from candidate_stage_events e where e.candidate_slug = p.cand) cand_name
    from pairs p
  ),
  valued as (
    select f.*, j.title job_title, cl.company_name client, c.name consultant,
      (select d.deal_value from deals d
        where d.deleted_at is null and d.job_slug = f.job
          and d.deal_stage = case f.stage when 'placed' then 'Won' when 'offered' then 'Offered' end
          and (d.deal_name ilike '%' || f.cand_name || '%'
               or (select count(*) from deals d2 where d2.deleted_at is null and d2.job_slug = f.job and d2.deal_stage = d.deal_stage) = 1)
        order by (d.deal_name ilike '%' || f.cand_name || '%') desc limit 1) deal_value
    from furthest f
    left join jobs j on j.slug = f.job
    left join clients cl on cl.id = j.client_id
    left join consultants c on c.recruitcrm_id = f.cid
    where p_consultant is null or c.name ilike '%' || p_consultant || '%'
  )
  select jsonb_build_object(
    'window', jsonb_build_object('from', (select f from w), 'to_exclusive', (select case when isfinite(t) then t end from w)),
    'scope', coalesce(p_consultant, 'Whole firm'),
    'definition', 'Claude''s part in deals, from the audit log and the /match suggestion log. sourced = the candidate was added to the job through Claude, or /match suggested them to that consultant and the same consultant sent their CV within 60 days (to that job, or any job when the search named none), and they were not already on the job. recorded = Claude only made a stage move on a pair it did not source (admin, not finding). won_value = the Won deal on the job of a sourced pair that reached Placed (billing); offered_value = the Offered deal of a sourced pair at Offered (pipeline, not billing). A deal is credited only when it names the candidate or is the job''s only deal at that stage. /match suggestions are logged from 05/11/2026, so earlier Claude finds that were added to jobs inside RecruitCRM are not counted: an undercount, never an overcount.',
    'sourced', jsonb_build_object(
      'pairs', (select count(*) from valued where kind = 'sourced'),
      'by_how', (select coalesce(jsonb_object_agg(how, n), '{}'::jsonb) from (select how, count(*) n from valued where kind = 'sourced' group by 1) x),
      'reached', jsonb_build_object(
        'cv_sent', (select count(*) from valued v join rank r on r.metric = v.stage where kind = 'sourced' and r.r >= 1),
        'interview_request', (select count(*) from valued v join rank r on r.metric = v.stage where kind = 'sourced' and r.r >= 2),
        'first_interview', (select count(*) from valued v join rank r on r.metric = v.stage where kind = 'sourced' and r.r >= 3),
        'offered', (select count(*) from valued v join rank r on r.metric = v.stage where kind = 'sourced' and r.r >= 6),
        'placed', (select count(*) from valued where kind = 'sourced' and stage = 'placed')),
      'won_value', (select coalesce(sum(deal_value), 0) from valued where kind = 'sourced' and stage = 'placed'),
      'offered_value', (select coalesce(sum(deal_value), 0) from valued where kind = 'sourced' and stage = 'offered'),
      'deals', (select coalesce(jsonb_agg(jsonb_build_object('candidate', cand_name, 'job', job_title, 'client', client, 'consultant', consultant,
                  'stage', stage, 'how', how, 'claude_at', at::date, 'deal_value', deal_value) order by stage = 'placed' desc, deal_value desc nulls last), '[]'::jsonb)
                from valued where kind = 'sourced' and stage in ('offered', 'placed'))),
    'recorded', jsonb_build_object(
      'pairs', (select count(*) from valued where kind = 'recorded'),
      'placed', (select count(*) from valued where kind = 'recorded' and stage = 'placed'),
      'won_value', (select coalesce(sum(deal_value), 0) from valued where kind = 'recorded' and stage = 'placed'),
      'deals', (select coalesce(jsonb_agg(jsonb_build_object('candidate', cand_name, 'job', job_title, 'client', client, 'consultant', consultant,
                  'stage', stage, 'claude_at', at::date, 'deal_value', deal_value) order by deal_value desc nulls last), '[]'::jsonb)
                from valued where kind = 'recorded' and stage in ('offered', 'placed'))),
    'by_consultant', (select coalesce(jsonb_agg(jsonb_build_object('consultant', consultant, 'sourced', s, 'cv_sent', cv, 'offered', o, 'placed', pl,
                  'won_value', wv, 'offered_value', ov) order by wv desc, ov desc, s desc), '[]'::jsonb)
                from (select coalesce(consultant, 'Unknown') consultant, count(*) s,
                        count(*) filter (where stage is not null) cv,
                        count(*) filter (where stage in ('offered', 'placed')) o, count(*) filter (where stage = 'placed') pl,
                        coalesce(sum(deal_value) filter (where stage = 'placed'), 0) wv, coalesce(sum(deal_value) filter (where stage = 'offered'), 0) ov
                      from valued where kind = 'sourced' group by 1) x),
    'suggestions_logged', (select count(*) from claude_suggestions s, w where s.suggested_at >= w.f and s.suggested_at < w.t)
  );
$function$;
revoke execute on function public.claude_deals(date, date, text) from public, anon, authenticated;
grant execute on function public.claude_deals(date, date, text) to service_role;
