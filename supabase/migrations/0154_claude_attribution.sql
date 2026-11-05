-- 0154_claude_attribution.sql
-- 05/11/2026 (#troubleshooting 1793816480.434949): the fee value Claude helped generate.
--
-- Rule ("Claude-assisted", full value): a Won deal counts, at its full deal value, when Claude made a
-- logged change on the deal's job, or on the candidate who reached Offered or Placed on that job,
-- before the deal's close date. The evidence is audit_log (via = 'claude'), which records every write
-- made through the Octagon connector against its record:
--   job        create_job, update_job, add_note, job_dpe on the deal's job
--   candidate  assign_candidate or update_hiring_stage on that job; create_candidate, update_candidate,
--              add_note or read_call_notes (intake) on the placed candidate
-- Billing follows the deal owner and the window is the deal's close date (start inclusive, end
-- exclusive), as in billing_report. Open pipeline counts deals not Won, Lost or Declined with a
-- Claude change on the job or on any candidate Claude assigned or moved on it.
-- Limits, stated in the output:
--   - audit_log starts 12/08/2026, so nothing before then can be attributed.
--   - Read-only help (match, interview prep, formatted CVs, adverts, Boolean, InMails) is not
--     logged against a record, so it is not counted. The figure is a floor, not an estimate.
--   - A job with several hires credits all its Won deals if Claude touched any placed candidate:
--     deals carry no candidate.
--   - Full value is a contribution, not a cause: the recruiter did the work.
-- Surfaced through usage_report() (the connector's usage_report tool, no release needed) and the
-- Friday usage post. The Friday line uses billing_report's quarter (close date anywhere in the
-- quarter), so its Won total matches /billing: on 05/11/2026, £20,200 of £86,037.75 Won (1 of 14
-- deals) and £167,500 of open pipeline (16 deals) were Claude-assisted.

create or replace function public.claude_attribution(p_from date default date '2026-01-01',
                                                     p_to date default (current_date + 1),
                                                     p_consultant text default null)
returns jsonb
language sql
stable security definer
set search_path to 'public'
as $fn$
with me as (select recruitcrm_id from consultants where p_consultant is not null and name = p_consultant limit 1),
deals_in as (
  select d.id, d.recruitcrm_id, d.job_slug, d.company_slug, d.deal_stage, d.deal_value, d.close_date, d.owner_recruitcrm_id
    from deals d
   where d.deleted_at is null and d.job_slug is not null
     and (p_consultant is null or d.owner_recruitcrm_id = (select recruitcrm_id from me))
     and ((d.deal_stage = 'Won' and d.close_date >= p_from and d.close_date < p_to)
          or d.deal_stage not in ('Won', 'Lost', 'Declined'))),
placed as (select distinct job_slug, candidate_slug from candidate_stage_events where stage_metric in ('placed', 'offered')),
touch as (
  -- the job itself
  select d.id, a.action, a.created_at from deals_in d
    join audit_log a on a.via = 'claude' and a.entity = 'job' and a.entity_id = d.job_slug
  union all
  -- Won: the placed candidate, on that job or on their record
  select d.id, a.action, a.created_at from deals_in d
    join placed p on p.job_slug = d.job_slug
    join audit_log a on a.via = 'claude' and a.entity = 'candidate' and a.entity_id = p.candidate_slug
     and (a.after->>'job_slug' = d.job_slug or a.action in ('create_candidate', 'update_candidate', 'add_note', 'read_call_notes'))
   where d.deal_stage = 'Won'
  union all
  -- Pipeline: any candidate Claude assigned or moved on the job
  select d.id, a.action, a.created_at from deals_in d
    join audit_log a on a.via = 'claude' and a.entity = 'candidate' and a.after->>'job_slug' = d.job_slug
   where d.deal_stage <> 'Won'),
scored as (
  select d.*,
         (select array_agg(distinct t.action order by t.action) from touch t
           where t.id = d.id and (d.deal_stage <> 'Won' or t.created_at::date <= d.close_date::date)) actions
    from deals_in d),
won as (select * from scored where deal_stage = 'Won'),
pipe as (select * from scored where deal_stage <> 'Won')
select jsonb_build_object(
  'window', jsonb_build_object('from', to_char(p_from, 'DD/MM/YYYY'), 'to_exclusive', to_char(p_to, 'DD/MM/YYYY')),
  'tracking_since', (select to_char(min(created_at), 'DD/MM/YYYY') from audit_log where via = 'claude'),
  'rule', 'Claude-assisted: a Won deal, at full value, where Claude made a logged change on its job or on the candidate placed on it, before the close date.',
  'won', jsonb_build_object(
    'deals', (select count(*) from won), 'value', (select coalesce(sum(deal_value), 0) from won),
    'assisted_deals', (select count(*) from won where actions is not null),
    'assisted_value', (select coalesce(sum(deal_value), 0) from won where actions is not null),
    'assisted_share_pct', (select round(100.0 * coalesce(sum(deal_value) filter (where actions is not null), 0) / nullif(sum(deal_value), 0), 1) from won)),
  'pipeline', jsonb_build_object(
    'deals', (select count(*) from pipe), 'value', (select coalesce(sum(deal_value), 0) from pipe),
    'assisted_deals', (select count(*) from pipe where actions is not null),
    'assisted_value', (select coalesce(sum(deal_value), 0) from pipe where actions is not null)),
  'by_consultant', (select coalesce(jsonb_agg(x order by (x->>'assisted_won_value')::numeric desc, x->>'name'), '[]'::jsonb) from (
      select jsonb_build_object('name', c.name, 'left', not coalesce(c.active, true) or c.deleted_at is not null,
               'won_value', coalesce(sum(s.deal_value) filter (where s.deal_stage = 'Won'), 0),
               'assisted_won_deals', count(*) filter (where s.deal_stage = 'Won' and s.actions is not null),
               'assisted_won_value', coalesce(sum(s.deal_value) filter (where s.deal_stage = 'Won' and s.actions is not null), 0),
               'assisted_pipeline_value', coalesce(sum(s.deal_value) filter (where s.deal_stage <> 'Won' and s.actions is not null), 0)) x
        from scored s join consultants c on c.recruitcrm_id = s.owner_recruitcrm_id
       group by c.name, c.active, c.deleted_at
      having count(*) filter (where s.actions is not null) > 0) q),
  'by_action', (select coalesce(jsonb_object_agg(action, n), '{}'::jsonb) from (
      select a action, count(*) n from scored, unnest(actions) a group by a) q),
  'assisted_deals', (select coalesce(jsonb_agg(jsonb_build_object(
        'stage', s.deal_stage, 'job', j.title, 'client', cl.company_name, 'owner', c.name, 'value', s.deal_value,
        'close_date', to_char(s.close_date, 'DD/MM/YYYY'), 'claude_actions', to_jsonb(s.actions))
        order by (s.deal_stage = 'Won') desc, s.deal_value desc nulls last), '[]'::jsonb)
      from (select * from scored where actions is not null order by (deal_stage = 'Won') desc, deal_value desc nulls last limit 25) s
      left join jobs j on j.slug = s.job_slug
      left join clients cl on cl.company_slug = s.company_slug and cl.deleted_at is null
      left join consultants c on c.recruitcrm_id = s.owner_recruitcrm_id),
  'notes', jsonb_build_array(
    'Counts only changes made through the Octagon connector, logged from 12/08/2026. Read-only help (match, interview prep, formatted CVs, adverts, Boolean, InMails) is not logged against a record, so this is a floor.',
    'Full deal value is credited where Claude contributed; it is not a claim that Claude caused the placement.',
    'A job with several hires credits each of its Won deals if Claude touched any candidate placed on it.')
);
$fn$;

revoke all on function public.claude_attribution(date, date, text) from public, anon, authenticated;
grant execute on function public.claude_attribution(date, date, text) to service_role;

-- usage_report() gains a claude_attribution block, so the connector's usage_report tool returns it.
do $do$
declare src text;
begin
  src := pg_get_functiondef('public.usage_report'::regproc);
  if position('claude_attribution' in src) = 0 then
    src := replace(src, E'  ) into res;\n  return res;',
                        E'  ) into res;\n  res := res || jsonb_build_object(''claude_attribution'', public.claude_attribution(p_from, p_to, p_consultant));\n  return res;');
    if position('claude_attribution' in src) = 0 then
      raise exception 'usage_report: return statement not found, nothing changed';
    end if;
    execute src;
  end if;
end
$do$;

-- The Friday usage post gains one line: Claude-assisted Won value this quarter, and pipeline.
do $do$
declare src text;
begin
  src := pg_get_functiondef('public.weekly_usage_post'::regproc);
  if position('claude_attribution' in src) = 0 then
    src := replace(src,
      E'    public.slack_context(''Counts only use of the Octagon connector',
      E'    public.slack_section(''*Claude-assisted fees this quarter*''||E''\\n''||(select\n'
      || E'        ''£''||to_char((a->''won''->>''assisted_value'')::numeric, ''FM999,999,990'')||'' Won across ''||(a->''won''->>''assisted_deals'')||'' of ''||(a->''won''->>''deals'')||'' deals''\n'
      || E'        ||'', and £''||to_char((a->''pipeline''->>''assisted_value'')::numeric, ''FM999,999,990'')||'' in pipeline (''||(a->''pipeline''->>''assisted_deals'')||'' deals). Full deal value where Claude made a logged change on the job or the placed candidate; read-only help is not counted.''\n'
      || E'        from (select public.claude_attribution(date_trunc(''quarter'', current_date)::date, (date_trunc(''quarter'', current_date) + interval ''3 months'')::date, null) a) q)),\n'
      || E'    public.slack_context(''Counts only use of the Octagon connector');
    if position('claude_attribution' in src) = 0 then
      raise exception 'weekly_usage_post: context block not found, nothing changed';
    end if;
    execute src;
  end if;
end
$do$;
