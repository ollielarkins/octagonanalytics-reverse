-- 0130_deals_by_consultant.sql
-- 28/10/2026: "give me deals offered and won" should split by consultant, e.g. "Keelan has 20 offers but
-- only 16 deals". Until now billing_report gave each person one in-play figure for every stage from
-- Open to Offered, and the Offered value only existed as a firm total.
--
-- deals_by_consultant(from, to, consultant) per person:
--   won_value / won_count        Won deals closed in the window, by deal owner (as billing_report)
--   won_later_value / _count     Won deals with a close date after the window. 12 deals (£75,660) had a
--                                future close date on 28/10/2026; an answer that ran its window to the
--                                financial year end counted them, and disagreed with fee_analysis
--   offered_value / offered_count deals at Offered now, by deal owner, whenever created
--   earlier_value / earlier_count deals at Open, CV Sent or an interview stage now
--   candidate_offers             candidates moved to Offered in the window, credited to whoever moved them
--   offers_without_deal          candidates whose latest stage is Offered (last 120 days) on a job with no
--                                deal at Offered, Won or Placed: an offer nobody has raised a deal for
-- Deal figures follow billing_report (deals as mirrored, by owner); offers follow the funnel (actor).
-- Leavers stay in, tagged left.
create or replace function public.deals_by_consultant(p_from date default null, p_to date default null, p_consultant text default null)
returns jsonb language sql stable security definer set search_path = public, pg_temp
as $function$
  with w as (select coalesce(p_from, make_date(extract(year from current_date)::int, 1, 1)) f, coalesce(p_to, current_date + 1) t),
  d as (
    select owner_recruitcrm_id rid,
      coalesce(sum(deal_value) filter (where deal_stage = 'Won' and close_date >= (select f from w) and close_date < (select t from w)), 0) won_value,
      count(*) filter (where deal_stage = 'Won' and close_date >= (select f from w) and close_date < (select t from w)) won_count,
      coalesce(sum(deal_value) filter (where deal_stage = 'Won' and close_date >= (select t from w)), 0) won_later_value,
      count(*) filter (where deal_stage = 'Won' and close_date >= (select t from w)) won_later_count,
      coalesce(sum(deal_value) filter (where deal_stage = 'Offered'), 0) offered_value,
      count(*) filter (where deal_stage = 'Offered') offered_count,
      coalesce(sum(deal_value) filter (where deal_stage in ('Open', 'CV Sent', 'Interview Request', '1st Interview', '2nd Interview', '3rd Interview')), 0) earlier_value,
      count(*) filter (where deal_stage in ('Open', 'CV Sent', 'Interview Request', '1st Interview', '2nd Interview', '3rd Interview')) earlier_count
    from deals group by owner_recruitcrm_id
  ),
  offers as (
    select e.consultant, count(distinct e.candidate_slug || '|' || e.job_slug) n
    from candidate_stage_events e join jobs j on j.slug = e.job_slug and j.deleted_at is null, w
    where e.stage_metric = 'offered' and e.event_date >= w.f and e.event_date < w.t
    group by 1
  ),
  latest as (
    select distinct on (e.candidate_slug, e.job_slug) e.candidate_slug, e.job_slug, e.stage_metric, e.consultant, e.event_date
    from candidate_stage_events e join jobs j on j.slug = e.job_slug and j.deleted_at is null
    where e.event_date >= current_date - 120
    order by e.candidate_slug, e.job_slug, e.event_timestamp desc
  ),
  nodeal as (
    select l.consultant, count(*) n from latest l
    where l.stage_metric = 'offered'
      and not exists (select 1 from deals dl where dl.job_slug = l.job_slug and dl.deal_stage in ('Offered', 'Won', 'Placed'))
    group by 1
  ),
  people as (
    select c.recruitcrm_id rid, c.name, not coalesce(c.active, true) as left_firm
    from consultants c where c.deleted_at is null
      and (p_consultant is null or c.name ilike '%' || p_consultant || '%')
  ),
  dr as (
    select p.name, p.left_firm,
      coalesce(d.won_value, 0) won_value, coalesce(d.won_count, 0) won_count,
      coalesce(d.won_later_value, 0) won_later_value, coalesce(d.won_later_count, 0) won_later_count,
      coalesce(d.offered_value, 0) offered_value, coalesce(d.offered_count, 0) offered_count,
      coalesce(d.earlier_value, 0) earlier_value, coalesce(d.earlier_count, 0) earlier_count,
      coalesce(o.n, 0) candidate_offers, coalesce(nd.n, 0) offers_without_deal
    from people p left join d on d.rid = p.rid left join offers o on o.consultant = p.name left join nodeal nd on nd.consultant = p.name
  )
  select jsonb_build_object(
    'window', (select jsonb_build_object('from', f, 'to_exclusive', t) from w),
    'definition', 'Per consultant. won_* = Won deals closed in the window, by deal owner, as billing counts them; won_later_* = Won deals with a close date after the window (not counted as billing in it). offered_* = deals at Offered now and earlier_* = deals at Open, CV Sent or an interview stage now, by deal owner, whenever created. candidate_offers = candidates moved to Offered in the window, credited to whoever moved them (an offer is not a deal and carries no fee). offers_without_deal = candidates whose latest stage is Offered (last 120 days) on a job with no deal at Offered, Won or Placed.',
    'consultants', (select coalesce(jsonb_agg(to_jsonb(r) order by r.won_value desc, r.offered_value desc, r.name), '[]'::jsonb) from dr r
                    where r.won_count + r.won_later_count + r.offered_count + r.earlier_count + r.candidate_offers + r.offers_without_deal > 0),
    'totals', (select jsonb_build_object('won_value', sum(won_value), 'won_count', sum(won_count), 'won_later_value', sum(won_later_value), 'won_later_count', sum(won_later_count), 'offered_value', sum(offered_value),
                 'offered_count', sum(offered_count), 'earlier_value', sum(earlier_value), 'earlier_count', sum(earlier_count),
                 'candidate_offers', sum(candidate_offers), 'offers_without_deal', sum(offers_without_deal)) from dr));
$function$;
revoke execute on function public.deals_by_consultant(date, date, text) from public, anon, authenticated;
grant execute on function public.deals_by_consultant(date, date, text) to service_role;
