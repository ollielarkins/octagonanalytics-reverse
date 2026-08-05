-- 0031_billing_report_definition.sql
-- Correct the billing_report() definition text now that deals are fully synced (migration added a
-- deals sync to recruitcrm-sync; the mirror went from 91 -> ~1,590 deals, Won 2 -> 859). Won-deal
-- revenue IS now the real billing figure, so the old "Won is sparse, use pipeline" caveat is removed.
-- Body/attribution unchanged from 0030.

create or replace function public.billing_report()
returns jsonb language sql stable security definer set search_path to 'public' as $function$
  with q as (select date_trunc('quarter', current_date)::date qs),
  d as (
    select owner_recruitcrm_id rid,
      coalesce(sum(deal_value) filter (where deal_stage='Won' and close_date >= (select qs from q)),0) won_qtr,
      coalesce(sum(deal_value) filter (where deal_stage='Won'),0) won_all,
      coalesce(sum(deal_value) filter (where deal_stage in ('Open','CV Sent','Interview Request','1st Interview','2nd Interview','3rd Interview','Offered')),0) pipeline_open
    from deals group by owner_recruitcrm_id
  ),
  base as (select recruitcrm_id rid, name from consultants where deleted_at is null and active)
  select jsonb_build_object(
    'quarter_start', (select qs from q),
    'definition', 'Quarter-to-date billing vs each recruiter''s quarterly target, attributed by deal owner. won_qtr = Won-deal revenue closed this quarter (the billing figure); won_all_time = all Won revenue on record; pipeline_open = value of in-play deals (Open->Offered) as a forward indicator. target is null where none is loaded.',
    'has_targets', (select count(*)>0 from billing_targets),
    'consultants', (select coalesce(jsonb_agg(jsonb_build_object(
        'name', b.name,
        'quarterly_target', (select quarterly_target from billing_targets t where t.consultant_recruitcrm_id=b.rid),
        'won_qtr', coalesce(d.won_qtr,0),
        'won_all_time', coalesce(d.won_all,0),
        'pipeline_open', coalesce(d.pipeline_open,0)
      ) order by (select quarterly_target from billing_targets t where t.consultant_recruitcrm_id=b.rid) desc nulls last), '[]'::jsonb)
     from base b left join d on d.rid=b.rid)
  );
$function$;
revoke all on function public.billing_report() from public, anon, authenticated;
grant execute on function public.billing_report() to service_role;
