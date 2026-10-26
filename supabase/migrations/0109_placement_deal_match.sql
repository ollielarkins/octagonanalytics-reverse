-- 0109_placement_deal_match.sql
-- Placements and Won deals, one to one (Bhav's priority 3, 20/10/2026).
--
-- Deals carry a job but no candidate, so placements_with_fees gave each placement the job's latest
-- Won deal. On 26/10/2026 that under-counted 12 placements whose job had more Won deals than
-- placements, and let two placements on one job share a deal. Decided 26/10/2026: a placement is
-- worth ONE Won deal; any other Won deal is a separate fee and is shown as unmatched, never summed.
--
-- placement_deal_match() pairs every placement with at most one Won deal on the same job, and every
-- Won deal with at most one placement. Greedy, best pair first: the candidate's full name in the
-- deal name, then their last name, then their first name (as whole words), then no name; ties go
-- to the deal created closest to the placement date. match_basis says which rule made the pair.
-- Billing is unchanged: it is still Won deal value by deal owner.

create or replace function public.placement_deal_match()
returns table (candidate_slug text, job_slug text, placed_on date, deal_recruitcrm_id bigint, match_basis text)
language plpgsql stable security definer set search_path = public, pg_temp
as $function$
#variable_conflict use_column
declare
  r record;
  used_pl text[] := '{}';
  used_deal bigint[] := '{}';
begin
  for r in
    with pl as (
      select e.candidate_slug, e.job_slug, max(e.event_date) placed_on,
             trim(max(e.candidate_name)) cand
      from candidate_stage_events e
      where e.stage_metric = 'placed'
      group by e.candidate_slug, e.job_slug
    ),
    pairs as (
      select pl.candidate_slug, pl.job_slug, pl.placed_on, d.recruitcrm_id,
             case
               when pl.cand <> '' and d.deal_name ilike '%' || pl.cand || '%' then 3
               when length(split_part(pl.cand, ' ', -1)) >= 3 and pl.cand like '% %'
                    and d.deal_name ~* ('\m' || regexp_replace(split_part(pl.cand, ' ', -1), '\W', '', 'g') || '\M') then 2
               -- Deal names often end with the consultant ("Plexus - Senior Electrical - Adam"), so a
               -- first name a consultant also has proves nothing.
               when length(split_part(pl.cand, ' ', 1)) >= 3
                    and not exists (select 1 from consultants c where split_part(c.name, ' ', 1) ilike split_part(pl.cand, ' ', 1))
                    and d.deal_name ~* ('\m' || regexp_replace(split_part(pl.cand, ' ', 1), '\W', '', 'g') || '\M') then 1
               else 0 end score,
             abs(coalesce(d.created_date, d.close_date)::date - pl.placed_on) gap
      from pl
      join deals d on d.job_slug = pl.job_slug and d.deal_stage = 'Won' and d.deleted_at is null
    )
    select * from pairs order by score desc, gap asc nulls last, placed_on, recruitcrm_id
  loop
    continue when (r.candidate_slug || '|' || r.job_slug) = any(used_pl) or r.recruitcrm_id = any(used_deal);
    used_pl := used_pl || (r.candidate_slug || '|' || r.job_slug);
    used_deal := used_deal || r.recruitcrm_id;
    candidate_slug := r.candidate_slug; job_slug := r.job_slug; placed_on := r.placed_on;
    deal_recruitcrm_id := r.recruitcrm_id;
    match_basis := case r.score when 3 then 'full_name' when 2 then 'last_name' when 1 then 'first_name' else 'same_job_nearest_date' end;
    return next;
  end loop;
end;
$function$;
revoke execute on function public.placement_deal_match() from public, anon, authenticated;
grant execute on function public.placement_deal_match() to service_role;

-- placements_with_fees: the matched deal per placement, the placements still without a Won deal
-- (overdue after p_overdue_days, 14 by default), and the Won deals that match no placement.
-- Added keys only, so the daily digest (0071) still reads 'placements' unchanged.
drop function if exists public.placements_with_fees(date, date, text);
create or replace function public.placements_with_fees(
  p_from date default (date_trunc('month', current_date))::date,
  p_to   date default (current_date + 1),
  p_consultant text default null,
  p_overdue_days integer default 14
)
returns jsonb language sql stable security definer set search_path = public, pg_temp
as $function$
  with m as (select * from public.placement_deal_match()),
  placed as (
    select e.candidate_slug, e.job_slug, max(e.event_date) placed_on,
           (select ev.consultant from candidate_stage_events ev
            where ev.candidate_slug=e.candidate_slug and ev.job_slug=e.job_slug
              and ev.stage_metric='placed' order by ev.event_timestamp desc limit 1) consultant
    from candidate_stage_events e
    join jobs j on j.slug=e.job_slug and j.deleted_at is null
    where e.stage_metric='placed' and e.event_date >= p_from and e.event_date < p_to
    group by e.candidate_slug, e.job_slug
  ),
  enriched as (
    select p.*, j.title job_title, m.match_basis,
           d.deal_name, d.deal_value, d.fee_percentage, d.annual_salary, d.close_date::date close_date
    from placed p
    left join jobs j on j.slug=p.job_slug
    left join m on m.candidate_slug=p.candidate_slug and m.job_slug=p.job_slug
    left join deals d on d.recruitcrm_id=m.deal_recruitcrm_id
    where (p_consultant is null or p.consultant ilike '%'||p_consultant||'%')
  ),
  unmatched as (
    select d.deal_name, d.deal_value, d.created_date::date created_on, d.close_date::date close_date,
           j.title job_title, co.name owner,
           case when d.job_slug is null then 'no_job_on_deal' else 'extra_won_deal_on_job' end reason
    from deals d
    left join jobs j on j.slug=d.job_slug
    left join consultants co on co.recruitcrm_id=d.owner_recruitcrm_id
    where d.deal_stage='Won' and d.deleted_at is null
      and d.created_date >= p_from and d.created_date < p_to
      and not exists (select 1 from m where m.deal_recruitcrm_id=d.recruitcrm_id)
      and (p_consultant is null or co.name ilike '%'||p_consultant||'%')
  )
  select jsonb_build_object(
    'window', jsonb_build_object('from', p_from, 'to', p_to),
    'definition', 'Placed stage events in the window, each matched to at most ONE Won deal on the same job, and each Won deal to at most one placement: candidate name in the deal name first, then the deal created nearest the placement date (match_basis says which). Other Won deals are separate fees, listed under unmatched_won_deals (created in the window) and never added to a placement. There is NO invoices table mirrored, so invoice status cannot be confirmed here - check RecruitCRM directly. A placement with no Won deal is a deal not yet moved to Won, not a missing placement.',
    'totals', (select jsonb_build_object(
        'placed', count(*),
        'with_won_deal', count(*) filter (where deal_value is not null),
        'missing_won_deal', count(*) filter (where deal_value is null),
        'overdue_no_won_deal', count(*) filter (where deal_value is null and placed_on < current_date - p_overdue_days),
        'overdue_after_days', p_overdue_days,
        'total_value', coalesce(sum(deal_value),0)) from enriched),
    'by_consultant', (select coalesce(jsonb_agg(jsonb_build_object(
        'name', consultant, 'placed', n, 'value', val) order by val desc nulls last, n desc), '[]'::jsonb)
      from (select consultant, count(*) n, coalesce(sum(deal_value),0) val
            from enriched where consultant is not null group by consultant) b),
    'placements', (select coalesce(jsonb_agg(jsonb_build_object(
        'candidate_job', job_title, 'consultant', consultant, 'placed_on', placed_on,
        'deal_value', deal_value, 'fee_pct', fee_percentage, 'annual_salary', annual_salary,
        'deal_close_date', close_date, 'deal_name', deal_name, 'match_basis', match_basis,
        'overdue_no_won_deal', (deal_value is null and placed_on < current_date - p_overdue_days))
        order by placed_on desc), '[]'::jsonb) from enriched),
    'unmatched_won_deals', (select jsonb_build_object(
        'count', count(*), 'value', coalesce(sum(deal_value),0),
        'deals', coalesce(jsonb_agg(jsonb_build_object(
          'deal_name', deal_name, 'deal_value', deal_value, 'job', job_title, 'owner', owner,
          'created_on', created_on, 'close_date', close_date, 'reason', reason)
          order by deal_value desc nulls last), '[]'::jsonb)) from unmatched)
  );
$function$;
revoke execute on function public.placements_with_fees(date, date, text, integer) from public, anon, authenticated;
grant execute on function public.placements_with_fees(date, date, text, integer) to service_role;

-- placements_report: counts and Won revenue by close date are unchanged (they match the dashboard).
-- It now also says what the placements in the window are worth through their matched Won deal, so
-- a placement whose deal closes later no longer reads as £0 billed.
create or replace function public.placements_report(p_from date default '2026-01-01', p_to date default '2100-01-01', p_consultant text default null, p_team text default null)
returns jsonb language sql stable security definer set search_path to 'public'
as $function$
  with pe as (
    select co.name consultant, cl.company_name client, e.candidate_slug, e.job_slug
    from candidate_stage_events e
    join jobs j on e.job_slug = j.slug and j.deleted_at is null
    join consultants co on j.consultant_id = co.id and co.deleted_at is null
    left join clients cl on j.client_id = cl.id and cl.deleted_at is null
    where e.stage_metric='placed' and e.event_date >= p_from and e.event_date < p_to
      and (p_consultant is null or co.name ilike '%'||p_consultant||'%')
      and (p_team is null or co.team = p_team)
  ),
  pv as (
    select p.candidate_slug, p.job_slug, d.deal_value
    from (select distinct candidate_slug, job_slug from pe) p
    left join public.placement_deal_match() m on m.candidate_slug=p.candidate_slug and m.job_slug=p.job_slug
    left join deals d on d.recruitcrm_id=m.deal_recruitcrm_id
  )
  select jsonb_build_object(
    'window', jsonb_build_object('from',p_from,'to',p_to),
    'definition','Placements = event-stream placed events. Revenue = sum of Won deal_value by close_date in the window (deals are often marked Won with a forward close date). placed_value = what the placements in the window are worth through their matched Won deal (one deal per placement, see placements_with_fees).',
    'placed_total', (select count(*) from pe),
    'won_revenue', (select coalesce(sum(deal_value),0) from deals
                    where deal_stage='Won' and close_date >= p_from and close_date < p_to),
    'placed_value', (select coalesce(sum(deal_value),0) from pv),
    'placed_missing_won_deal', (select count(*) from pv where deal_value is null),
    'by_consultant', (select coalesce(jsonb_agg(jsonb_build_object('name',consultant,'placed',n)
        order by n desc), '[]'::jsonb) from (select consultant, count(*) n from pe group by consultant) c),
    'by_client', (select coalesce(jsonb_agg(jsonb_build_object('client',client,'placed',n)
        order by n desc), '[]'::jsonb) from (select client, count(*) n from pe where client is not null group by client) c)
  );
$function$;
