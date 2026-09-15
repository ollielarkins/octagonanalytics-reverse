-- 0076_reconcile_deals_soft_delete.sql
-- reconcile_deals was the one reconcile that destroyed rows:
--
--   delete from public.deals where recruitcrm_id is not null and not (recruitcrm_id = any(p_live_ids));
--
-- Every other entity has tombstoned since 0007. Deals hard-deleted for one reason only — the table
-- had no deleted_at column, so there was nowhere to mark it. 0075 added one.
--
-- Why this mattered enough to fix immediately: deals carry billing. A Won deal removed here takes its
-- value out of the mirror permanently, with no restore and no record it ever existed, and the only
-- guard was "did the paged fetch complete". The mirror holds 1,640 deals against a last live fetch of
-- 1,567 ids, so a run had roughly 73 rows in scope. 0074 had just restored this job to hourly at :18,
-- which turned a dormant risk into an imminent one.
--
-- Now identical in shape to reconcile_entity: tombstone what is gone, restore what returns.
-- Billing history is unaffected either way — revenue_monthly does not filter deleted_at, deliberately,
-- per the 15/09/2026 decision that deletions hide from operational surfaces but never rewrite history.

create or replace function public.reconcile_deals(p_live_ids bigint[])
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_deleted int; v_restored int;
begin
  if p_live_ids is null or array_length(p_live_ids, 1) is null then
    return jsonb_build_object('skipped', true, 'reason', 'no live ids');
  end if;

  update public.deals set deleted_at = now()
   where deleted_at is null
     and recruitcrm_id is not null
     and not (recruitcrm_id = any(p_live_ids));
  get diagnostics v_deleted = row_count;

  update public.deals set deleted_at = null
   where deleted_at is not null
     and recruitcrm_id = any(p_live_ids);
  get diagnostics v_restored = row_count;

  return jsonb_build_object('soft_deleted', v_deleted, 'restored', v_restored, 'live_ids', array_length(p_live_ids, 1));
end $function$;
