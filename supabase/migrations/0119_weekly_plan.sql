-- 0119_weekly_plan.sql
-- Priority 5 (Bhav, 20/10/2026): weekly targets worked back from each consultant's quarterly billing
-- target and their own conversion ratios, instead of flat targets. Decided 26/10/2026:
--  * Run-rate, not catch-up: a quarter's target spread over 13 weeks. A CV sent in December rarely
--    bills by 31/12, so "close the gap by quarter end" would only spike late. The quarter's position
--    is shown alongside.
--  * Never below the flat weekly minimums (weekly_targets: 10 CVs, 5 interview requests, 4 interviews).
--  * Small samples blend with the firm's ratios: each ratio is shrunk towards the firm's
--    (own_num + k * firm_rate) / (own_den + k), so a couple of lucky placements don't set the plan.
--    k = 40 CVs, 40 CVs, 20 first interviews, 5 offers.
--  * No billing target (Will Drake, 26/10/2026): no plan from billing, just the flat minimums, and
--    the DM says so. Decided the same day: the firm median gave Will 26 CVs a week, about 13 times his
--    6-month rate.
--  * Median fee from the consultant's Won deals in 12 months, or the firm's if they have fewer than 4.
-- Monday: a plan line in the 08:30 DM. Friday: actuals against plan in the end-of-week email.

create or replace function public.weekly_plan(p_consultant bigint default null)
returns jsonb language sql stable security definer set search_path = public, pg_temp
as $function$
  with wk as (select date_trunc('week', (now() at time zone 'Europe/London'))::date ws),
  qtr as (select date_trunc('quarter', (now() at time zone 'Europe/London'))::date qs),
  people as (
    select c.recruitcrm_id, c.name from consultants c
    where c.deleted_at is null and coalesce(c.active, true)
      and (p_consultant is null or c.recruitcrm_id = p_consultant)
      and exists (select 1 from candidate_stage_events e where e.consultant = c.name and e.event_date >= current_date - 182)
  ),
  ev as (   -- last 6 months, distinct candidate-job pairs, credited to whoever moved the stage
    select e.consultant, e.stage_metric, count(distinct e.candidate_slug||'|'||e.job_slug) n
    from candidate_stage_events e join jobs j on j.slug = e.job_slug and j.deleted_at is null
    where e.event_date >= current_date - 182
      and e.stage_metric in ('cv_sent','interview_request','first_interview','offered','placed')
    group by 1, 2
  ),
  firm as (
    select sum(n) filter (where stage_metric='cv_sent')::numeric cv, sum(n) filter (where stage_metric='interview_request')::numeric ir,
           sum(n) filter (where stage_metric='first_interview')::numeric iv, sum(n) filter (where stage_metric='offered')::numeric ofr,
           sum(n) filter (where stage_metric='placed')::numeric pl
    from ev
  ),
  firm_rates as (
    select ir / nullif(cv, 0) ir_cv, iv / nullif(cv, 0) iv_cv, ofr / nullif(iv, 0) of_iv, pl / nullif(ofr, 0) pl_of from firm
  ),
  firm_fee as (
    select percentile_cont(0.5) within group (order by deal_value) fee from deals
    where deal_stage = 'Won' and deleted_at is null and deal_value > 0 and coalesce(close_date, created_date) >= now() - interval '12 months'
  ),
  own as (
    select p.recruitcrm_id, p.name,
           coalesce((select n from ev where consultant = p.name and stage_metric='cv_sent'), 0)::numeric cv,
           coalesce((select n from ev where consultant = p.name and stage_metric='interview_request'), 0)::numeric ir,
           coalesce((select n from ev where consultant = p.name and stage_metric='first_interview'), 0)::numeric iv,
           coalesce((select n from ev where consultant = p.name and stage_metric='offered'), 0)::numeric ofr,
           coalesce((select n from ev where consultant = p.name and stage_metric='placed'), 0)::numeric pl,
           bt.quarterly_target,
           (select count(*) from deals d where d.owner_recruitcrm_id = p.recruitcrm_id and d.deal_stage='Won' and d.deleted_at is null
              and d.deal_value > 0 and coalesce(d.close_date, d.created_date) >= now() - interval '12 months') won_n,
           (select percentile_cont(0.5) within group (order by d.deal_value) from deals d where d.owner_recruitcrm_id = p.recruitcrm_id
              and d.deal_stage='Won' and d.deleted_at is null and d.deal_value > 0 and coalesce(d.close_date, d.created_date) >= now() - interval '12 months') own_fee,
           (select coalesce(sum(d.deal_value), 0) from deals d, qtr where d.owner_recruitcrm_id = p.recruitcrm_id and d.deal_stage='Won'
              and d.deleted_at is null and d.close_date >= qtr.qs and d.close_date < qtr.qs + interval '3 months') won_q
    from people p left join billing_targets bt on bt.consultant_recruitcrm_id = p.recruitcrm_id
  ),
  calc as (
    select o.*,
           nullif(o.quarterly_target, 0)::numeric target,
           case when nullif(o.quarterly_target, 0) is null then 'none set: flat minimums only' else 'billing target' end target_source,
           (case when o.won_n >= 4 then o.own_fee else (select fee from firm_fee) end)::numeric fee,
           case when o.won_n >= 4 then 'own median, 12 months' else 'firm median (fewer than 4 Won deals)' end fee_source,
           (o.ir  + 40 * f.ir_cv) / (o.cv + 40) ir_cv,
           (o.iv  + 40 * f.iv_cv) / (o.cv + 40) iv_cv,
           (o.ofr + 20 * f.of_iv) / (o.iv + 20) of_iv,
           (o.pl  +  5 * f.pl_of) / (o.ofr + 5) pl_of,
           o.cv < 40 or o.iv < 20 or o.ofr < 5 blended,
           f.ir_cv f_ir_cv, f.iv_cv f_iv_cv, f.of_iv f_of_iv, f.pl_of f_pl_of
    from own o cross join firm_rates f
  ),
  need as (
    select c.*,
           c.target / nullif(c.fee, 0) q_placed,
           c.target / nullif(c.fee, 0) / nullif(c.pl_of, 0) q_offers,
           c.target / nullif(c.fee, 0) / nullif(c.pl_of, 0) / nullif(c.of_iv, 0) q_iv,
           c.target / nullif(c.fee, 0) / nullif(c.pl_of, 0) / nullif(c.of_iv, 0) / nullif(c.iv_cv, 0) q_cv
    from calc c
  ),
  week_act as (
    select e.consultant, e.stage_metric, count(distinct e.candidate_slug||'|'||e.job_slug) n
    from candidate_stage_events e join jobs j on j.slug = e.job_slug and j.deleted_at is null, wk
    where e.event_date >= wk.ws group by 1, 2
  ),
  plan_rows as (
    select n.*,
           ceil(n.q_cv / 13) raw_cv, ceil(n.q_cv * n.ir_cv / 13) raw_ir, ceil(n.q_iv / 13) raw_iv, ceil(n.q_offers / 13 * 10) / 10 raw_of,
           coalesce((select weekly_target from weekly_targets w where w.consultant_recruitcrm_id = n.recruitcrm_id and w.metric = 'cv_sent'), 10) floor_cv,
           coalesce((select weekly_target from weekly_targets w where w.consultant_recruitcrm_id = n.recruitcrm_id and w.metric = 'interview_request'), 5) floor_ir,
           coalesce((select weekly_target from weekly_targets w where w.consultant_recruitcrm_id = n.recruitcrm_id and w.metric = 'first_interview'), 4) floor_iv,
           coalesce((select a.n from week_act a where a.consultant = n.name and a.stage_metric = 'cv_sent'), 0) a_cv,
           coalesce((select a.n from week_act a where a.consultant = n.name and a.stage_metric = 'interview_request'), 0) a_ir,
           coalesce((select a.n from week_act a where a.consultant = n.name and a.stage_metric = 'first_interview'), 0) a_iv,
           coalesce((select a.n from week_act a where a.consultant = n.name and a.stage_metric = 'offered'), 0) a_of,
           -- The step furthest below the firm, as a share of the firm's rate: the ratio to work on.
           (select s.step from (values
              ('CV to interview', n.iv_cv / nullif(n.f_iv_cv, 0)),
              ('interview to offer', n.of_iv / nullif(n.f_of_iv, 0)),
              ('offer to placement', n.pl_of / nullif(n.f_pl_of, 0))) s(step, rel)
            where s.rel < 0.95 order by s.rel asc limit 1) weakest
    from need n
  )
  select jsonb_build_object(
    'week_start', (select ws from wk), 'quarter_start', (select qs from qtr), 'weeks_in_quarter', 13,
    'method', 'Run-rate: quarterly target / median fee = placements, worked back through the consultant''s own 6-month ratios (blended with the firm''s when the sample is small), spread over 13 weeks, never below the flat weekly minimums.',
    'consultants', coalesce((select jsonb_agg(jsonb_build_object(
        'consultant', r.name,
        'target', round(r.target), 'target_source', r.target_source,
        'median_fee', round(r.fee), 'fee_source', r.fee_source,
        'ratios', jsonb_build_object('cv_to_interview_pct', round(100 * r.iv_cv, 1), 'interview_to_offer_pct', round(100 * r.of_iv, 1),
                    'offer_to_placed_pct', round(100 * r.pl_of, 1), 'blended_with_firm', r.blended),
        'quarter_needs', jsonb_build_object('placements', round(r.q_placed, 1), 'offers', round(r.q_offers, 1),
                    'first_interviews', round(r.q_iv), 'cvs', round(r.q_cv)),
        'plan', jsonb_build_object('cv_sent', greatest(r.raw_cv, r.floor_cv), 'interview_request', greatest(r.raw_ir, r.floor_ir),
                    'first_interview', greatest(r.raw_iv, r.floor_iv), 'offered', round(r.raw_of, 1)),
        'from_billing', jsonb_build_object('cv_sent', r.raw_cv, 'interview_request', r.raw_ir, 'first_interview', r.raw_iv),
        'floor', jsonb_build_object('cv_sent', r.floor_cv, 'interview_request', r.floor_ir, 'first_interview', r.floor_iv),
        'this_week', jsonb_build_object('cv_sent', r.a_cv, 'interview_request', r.a_ir, 'first_interview', r.a_iv, 'offered', r.a_of),
        'ratio_to_work_on', r.weakest,
        'quarter_position', jsonb_build_object('won_by_close_date', round(r.won_q), 'target', round(r.target),
                    'pct', round(100 * r.won_q / nullif(r.target, 0), 1)))
      order by r.name) from plan_rows r), '[]'::jsonb));
$function$;
revoke execute on function public.weekly_plan(bigint) from public, anon, authenticated;
grant execute on function public.weekly_plan(bigint) to service_role;

-- action_queue: a Monday line with this week's plan. Guarded edit, inserted before the client-visits
-- line; nothing else changes.
do $do$
declare
  def text := pg_get_functiondef('public.action_queue(bigint)'::regprocedure);
  anchor text := $a$    union all
    select 3, jsonb_build_object('kind', 'client_visits'$a$;
  addition text := $b$    union all
    select 0, jsonb_build_object('kind', 'plan', 'item_key', 'plan:'||to_char(current_date, 'IYYY-IW'),
           'action', 'This week''s plan: '||(pl.x->'plan'->>'cv_sent')||' CVs, '||(pl.x->'plan'->>'interview_request')||' interview requests, '
                     ||(pl.x->'plan'->>'first_interview')||' first interviews',
           'who', case when pl.x->>'target' is null then 'The flat minimums: no quarterly billing target is set for you yet'
                       else 'Worked back from your £'||to_char((pl.x->>'target')::numeric, 'FM999,999')||' quarter' end
                  ||coalesce(', and '||(pl.x->>'ratio_to_work_on')||' is the step to work on', ''))
    from (select x from jsonb_array_elements(public.weekly_plan(p_consultant)->'consultants') x) pl
    where extract(isodow from current_date) = 1
$b$;
begin
  if position('public.weekly_plan(' in def) > 0 then
    return;   -- already applied
  end if;
  if (length(def) - length(replace(def, anchor, ''))) / length(anchor) <> 1 then
    raise exception '0119: action_queue anchor not found exactly once; it has changed since 0118';
  end if;
  execute replace(def, anchor, addition || anchor);
end;
$do$;
