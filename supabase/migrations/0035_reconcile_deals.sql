-- 0035_reconcile_deals.sql
-- Deals are a re-syncable mirror with nothing FK'd to them by id, and the table has no deleted_at
-- column — so delete-detection is a hard delete (removed rows just drop out of the pipeline/Won sums
-- in dashboard_json and billing_report; no query changes needed). Guarded: only deletes when a
-- non-empty live-id set is supplied, so a failed/empty fetch can never wipe the table.

create or replace function public.reconcile_deals(p_live_ids bigint[])
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare deleted int;
begin
  if p_live_ids is null or array_length(p_live_ids, 1) is null then
    return jsonb_build_object('skipped', true, 'reason', 'no live ids');
  end if;
  delete from public.deals where recruitcrm_id is not null and not (recruitcrm_id = any(p_live_ids));
  get diagnostics deleted = row_count;
  return jsonb_build_object('deleted', deleted, 'live_ids', array_length(p_live_ids, 1));
end $function$;
revoke all on function public.reconcile_deals(bigint[]) from public, anon, authenticated;
grant execute on function public.reconcile_deals(bigint[]) to service_role;

-- Nightly deals reconcile (staggered after the other reconciles). Auth via anon key, per 0007.
do $$
declare
  auth text := 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imt6Y21zc2xkdnRqbmJ3d3VudXdtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzgwNTExMTIsImV4cCI6MjA5MzYyNzExMn0.ptlngXNjvjlEvAhPCiLGFvbRT7nA0zfr4MW-gqtPYRk';
begin
  perform cron.schedule('recruitcrm-reconcile-deals', '30 3 * * *', format(
    $q$select net.http_post(url:=%L, headers:=jsonb_build_object('Authorization',%L,'Content-Type','application/json'), body:='{}'::jsonb, timeout_milliseconds:=55000);$q$,
    'https://kzcmssldvtjnbwwunuwm.supabase.co/functions/v1/recruitcrm-sync?mode=reconcile&entity=deals', auth));
end $$;
