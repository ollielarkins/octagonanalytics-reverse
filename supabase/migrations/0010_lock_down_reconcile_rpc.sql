-- 0010_lock_down_reconcile_rpc.sql
-- Cleanup: reconcile_entity() is SECURITY DEFINER and was still callable by
-- anon/authenticated via /rest/v1/rpc (the default PUBLIC execute grant that
-- 0006's revoke didn't cover). It must only run from the sync function (service
-- role). Revoke from everyone, grant to service_role only.

revoke execute on function public.reconcile_entity(text, bigint[]) from public;
revoke execute on function public.reconcile_entity(text, bigint[]) from anon, authenticated;
grant  execute on function public.reconcile_entity(text, bigint[]) to service_role;
