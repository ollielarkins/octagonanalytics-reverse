-- 0006_soft_delete_reconcile.sql
-- Hard-delete detection via periodic full-ID reconciliation, applied as a
-- SOFT delete (deleted_at) so history is preserved and FKs don't break.

alter table public.consultants add column if not exists deleted_at timestamptz;
alter table public.clients     add column if not exists deleted_at timestamptz;
alter table public.jobs        add column if not exists deleted_at timestamptz;

-- Reconcile one entity against the complete set of live RecruitCRM ids.
-- Soft-deletes mirror rows whose recruitcrm_id is no longer live; restores any
-- previously-deleted row that has reappeared. SAFETY: refuses to run on an empty
-- id set (a failed fetch must never wipe the table).
create or replace function public.reconcile_entity(p_table text, p_live_ids bigint[])
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_deleted int; v_restored int;
begin
  if p_table not in ('consultants','clients','jobs') then
    raise exception 'reconcile_entity: table % not allowed', p_table;
  end if;
  if coalesce(array_length(p_live_ids, 1), 0) = 0 then
    return jsonb_build_object('error', 'empty_live_ids — refused');
  end if;

  execute format(
    'update public.%I set deleted_at = now() where deleted_at is null and not (recruitcrm_id = any($1))',
    p_table
  ) using p_live_ids;
  get diagnostics v_deleted = row_count;

  execute format(
    'update public.%I set deleted_at = null where deleted_at is not null and recruitcrm_id = any($1)',
    p_table
  ) using p_live_ids;
  get diagnostics v_restored = row_count;

  return jsonb_build_object('soft_deleted', v_deleted, 'restored', v_restored);
end $$;

revoke all on function public.reconcile_entity(text, bigint[]) from anon, authenticated;
