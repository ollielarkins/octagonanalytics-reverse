-- 0030_billing_targets.sql
-- Quarterly per-recruiter billing targets + a quarter-to-date billing report.
--
-- Attribution: deals.owner_recruitcrm_id (direct owner). Quarter starts on the calendar quarter.
-- DATA CAVEAT: Won-deal fee data is very sparse (only a couple of Won deals carry value; "Placed"
-- deals carry 0). So won_qtr will read near zero for almost everyone — it is NOT a reliable billing
-- figure yet. pipeline_open (value of in-play deals, Open→Offered) IS populated and is the more
-- meaningful leading indicator until real fee/placement data flows. See README / project memory.

create table if not exists public.billing_targets (
  consultant_recruitcrm_id bigint primary key,
  quarterly_target         numeric not null,
  updated_at               timestamptz not null default now()
);
alter table public.billing_targets enable row level security;
drop policy if exists billing_targets_read_auth on public.billing_targets;
create policy billing_targets_read_auth on public.billing_targets for select to authenticated using (true);

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
    'definition', 'Quarter-to-date billing vs each recruiter''s quarterly target, attributed by deal owner. won_qtr = Won-deal revenue closed this quarter; won_all_time = all Won revenue; pipeline_open = value of in-play deals (Open->Offered). CAVEAT: Won-fee data is very sparse, so won_qtr reads near zero and pipeline_open is the meaningful leading indicator. target is null until loaded.',
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

-- Load quarterly billing targets (owner-given 2026-08-05). recruitcrm_id is RecruitCRM's stable key.
insert into public.billing_targets (consultant_recruitcrm_id, quarterly_target) values
  (77535, 45000),   -- Keelan Riley
  (77584, 42000),   -- Scott Newcomen
  (99374, 42000),   -- Tarah Williams
  (77603, 38000),   -- Adam Barnett
  (130394, 36000),  -- Georgia Cook
  (65639, 30000),   -- Bhavesh Patel ("Bhav")
  (72000, 30000)    -- Steve Bernat
on conflict (consultant_recruitcrm_id) do update set quarterly_target = excluded.quarterly_target, updated_at = now();
-- Will Drake (154036) target is TBC — intentionally not loaded.
