-- 0136_leaver_revoke_and_billing_split.sql
-- Two features from the platform audit (29/10/2026), added 30/10/2026.
--
-- 1. Leavers lose access automatically. A leaver kept a write-enabled token until someone noticed
--    (Scott Newcomen, revoked by hand 29/10/2026). When a consultant is marked inactive or deleted,
--    their connector tokens are switched off and their inbox stops being polled, with an audit row.
--    Admin tokens (consultant id 0) are never touched. Existing leavers are swept once here.
-- 2. Billing shows closed-to-date and later-this-quarter separately. Every Q4 Won deal on 29/10/2026
--    was dated in December, so "won this quarter" mixed money closed with money dated ahead. won_qtr
--    is unchanged; won_to_date and won_later_this_quarter split it. The quarter is now taken in UK
--    time, like the rest of the platform.

create or replace function public.revoke_leaver_access()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare n int;
begin
  if new.recruitcrm_id is null or new.recruitcrm_id = 0 then return new; end if;
  if (coalesce(old.active, true) and not coalesce(new.active, true))
     or (old.deleted_at is null and new.deleted_at is not null) then
    update mcp_tokens set active = false where consultant_recruitcrm_id = new.recruitcrm_id and active;
    get diagnostics n = row_count;
    update inbox_mailboxes set enabled = false where consultant_recruitcrm_id = new.recruitcrm_id and enabled;
    if n > 0 then
      insert into audit_log (actor, action, entity, entity_id, before, after, via)
      values ('system', 'token_auto_revoke', 'consultant', new.recruitcrm_id::text, null,
              jsonb_build_object('name', new.name, 'tokens_revoked', n), 'trigger');
    end if;
  end if;
  return new;
end;
$$;
revoke execute on function public.revoke_leaver_access() from public, anon, authenticated;

drop trigger if exists consultants_revoke_leaver_access on public.consultants;
create trigger consultants_revoke_leaver_access
  after update of active, deleted_at on public.consultants
  for each row execute function public.revoke_leaver_access();

-- One-off sweep for anyone who has already left.
with gone as (
  select recruitcrm_id, name from consultants
   where recruitcrm_id <> 0 and (not coalesce(active, true) or deleted_at is not null)
),
revoked as (
  update mcp_tokens t set active = false from gone g
   where t.consultant_recruitcrm_id = g.recruitcrm_id and t.active
  returning g.recruitcrm_id, g.name
)
insert into audit_log (actor, action, entity, entity_id, before, after, via)
select 'system', 'token_auto_revoke', 'consultant', recruitcrm_id::text, null,
       jsonb_build_object('name', name, 'tokens_revoked', count(*)), 'migration 0136'
  from revoked group by recruitcrm_id, name;
update inbox_mailboxes m set enabled = false from consultants c
 where c.recruitcrm_id = m.consultant_recruitcrm_id and c.recruitcrm_id <> 0
   and (not coalesce(c.active, true) or c.deleted_at is not null) and m.enabled;

create or replace function public.billing_report()
returns jsonb
language sql
stable security definer
set search_path to 'public'
as $function$
  with q as (select date_trunc('quarter', (now() at time zone 'Europe/London')::date)::date qs, (now() at time zone 'Europe/London')::date td),
  d as (
    select owner_recruitcrm_id rid,
      coalesce(sum(deal_value) filter (where deal_stage='Won' and close_date >= (select qs from q) and close_date <= (select td from q)),0) won_to_date,
      coalesce(sum(deal_value) filter (where deal_stage='Won' and close_date > (select td from q) and close_date < (select qs from q) + interval '3 months'),0) won_later,
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
    'definition', 'Quarter billing vs each recruiter''s quarterly target, attributed by deal owner. won_qtr = Won-deal revenue with a close date in this quarter (the billing figure; a close date later in the quarter counts), split into won_to_date (closed on or before today) and won_later_this_quarter (Won but dated after today); won_all_time = all Won revenue on record; pipeline_open = value of in-play deals (Open->Offered) as a forward indicator. Deleted deals are excluded. Leavers appear tagged left when they own Won revenue this quarter or open pipeline. target is null where none is loaded.',
    'has_targets', (select count(*)>0 from billing_targets),
    'consultants', (select coalesce(jsonb_agg(jsonb_build_object(
        'name', b.name,
        'left', b.gone,
        'quarterly_target', (select quarterly_target from billing_targets t where t.consultant_recruitcrm_id=b.rid),
        'won_qtr', coalesce(d.won_qtr,0),
        'won_to_date', coalesce(d.won_to_date,0),
        'won_later_this_quarter', coalesce(d.won_later,0),
        'won_all_time', coalesce(d.won_all,0),
        'pipeline_open', coalesce(d.pipeline_open,0)
      ) order by b.gone, (select quarterly_target from billing_targets t where t.consultant_recruitcrm_id=b.rid) desc nulls last), '[]'::jsonb)
     from base b left join d on d.rid=b.rid)
  );
$function$;
