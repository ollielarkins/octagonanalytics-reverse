-- 0133_billing_bounds_and_pipeline.sql
-- Billing and pipeline figures that agree with each other and leave out deleted deals.
-- Found in the platform audit, 29/10/2026.
--
-- billing_report():
--   - won_qtr had no upper bound: every Won deal closing on or after the quarter start counted,
--     including later quarters. It now ends at the quarter end, the same window weekly_plan's
--     won_by_close_date has always used, so the billing tool and the plan cannot disagree.
--   - Deleted deals counted (a deleted Won deal was in Q4 on 29/10/2026). Now excluded.
--   - Leavers were dropped (base was active consultants only), against the rule that leavers stay
--     in totals, tagged left. A leaver now appears, tagged left, when they own Won revenue this
--     quarter or open pipeline; with neither they are left out to keep the scorecard short.
-- dashboard_json():
--   - open_pipeline was "not Won or Lost", which took in Declined, Placed and deleted deals, so it
--     ran far above billing's figure. It now uses billing's definition, Open to Offered, not
--     deleted.
--   - won and the stage breakdown now leave out deleted deals.
-- deals_by_consultant(): leaves out deleted deals, including in the "offer with no deal" check.

create or replace function public.billing_report()
returns jsonb
language sql
stable security definer
set search_path to 'public'
as $function$
  with q as (select date_trunc('quarter', current_date)::date qs),
  d as (
    select owner_recruitcrm_id rid,
      coalesce(sum(deal_value) filter (where deal_stage='Won' and close_date >= (select qs from q) and close_date < (select qs from q) + interval '3 months'),0) won_qtr,
      coalesce(sum(deal_value) filter (where deal_stage='Won'),0) won_all,
      coalesce(sum(deal_value) filter (where deal_stage in ('Open','CV Sent','Interview Request','1st Interview','2nd Interview','3rd Interview','Offered')),0) pipeline_open
    from deals where deleted_at is null group by owner_recruitcrm_id
  ),
  base as (
    select c.recruitcrm_id rid, c.name, not coalesce(c.active, true) as gone
      from consultants c left join d on d.rid = c.recruitcrm_id
     where c.deleted_at is null
       and (coalesce(c.active, true) or coalesce(d.won_qtr,0) <> 0 or coalesce(d.pipeline_open,0) <> 0)
  )
  select jsonb_build_object(
    'quarter_start', (select qs from q),
    'quarter_end_exclusive', (select (qs + interval '3 months')::date from q),
    'definition', 'Quarter billing vs each recruiter''s quarterly target, attributed by deal owner. won_qtr = Won-deal revenue with a close date in this quarter (the billing figure; a close date later in the quarter counts); won_all_time = all Won revenue on record; pipeline_open = value of in-play deals (Open->Offered) as a forward indicator. Deleted deals are excluded. Leavers appear tagged left when they own Won revenue this quarter or open pipeline. target is null where none is loaded.',
    'has_targets', (select count(*)>0 from billing_targets),
    'consultants', (select coalesce(jsonb_agg(jsonb_build_object(
        'name', b.name,
        'left', b.gone,
        'quarterly_target', (select quarterly_target from billing_targets t where t.consultant_recruitcrm_id=b.rid),
        'won_qtr', coalesce(d.won_qtr,0),
        'won_all_time', coalesce(d.won_all,0),
        'pipeline_open', coalesce(d.pipeline_open,0)
      ) order by b.gone, (select quarterly_target from billing_targets t where t.consultant_recruitcrm_id=b.rid) desc nulls last), '[]'::jsonb)
     from base b left join d on d.rid=b.rid)
  );
$function$;

-- Guarded edits per 0083: each replaced text must be there, or the migration raises.
do $$
declare
  def text;
  new_def text;
  r record;
begin
  select pg_get_functiondef('public.dashboard_json'::regproc) into def;
  new_def := def;
  for r in select * from (values
    ($a$(select coalesce(sum(deal_value),0) from deals where deal_stage not in ('Won','Lost'))$a$,
     $b$(select coalesce(sum(deal_value),0) from deals where deleted_at is null and deal_stage in ('Open','CV Sent','Interview Request','1st Interview','2nd Interview','3rd Interview','Offered'))$b$),
    ($a$(select coalesce(sum(deal_value),0) from deals where deal_stage='Won')$a$,
     $b$(select coalesce(sum(deal_value),0) from deals where deal_stage='Won' and deleted_at is null)$b$),
    ($a$coalesce(sum(deal_value),0) v from deals group by deal_stage$a$,
     $b$coalesce(sum(deal_value),0) v from deals where deleted_at is null group by deal_stage$b$)
  ) v(old_text, new_text) loop
    if position(r.old_text in new_def) = 0 then raise exception '0133: dashboard_json no longer contains: %', r.old_text; end if;
    new_def := replace(new_def, r.old_text, r.new_text);
  end loop;
  execute new_def;

  select pg_get_functiondef('public.deals_by_consultant(date, date, text)'::regprocedure) into def;
  new_def := def;
  for r in select * from (values
    ($a$from deals group by owner_recruitcrm_id$a$,
     $b$from deals where deleted_at is null group by owner_recruitcrm_id$b$),
    ($a$where dl.job_slug = l.job_slug and dl.deal_stage in ('Offered', 'Won', 'Placed')$a$,
     $b$where dl.job_slug = l.job_slug and dl.deleted_at is null and dl.deal_stage in ('Offered', 'Won', 'Placed')$b$)
  ) v(old_text, new_text) loop
    if position(r.old_text in new_def) = 0 then raise exception '0133: deals_by_consultant no longer contains: %', r.old_text; end if;
    new_def := replace(new_def, r.old_text, r.new_text);
  end loop;
  execute new_def;
end $$;
