-- 0007_schedule_reconcile.sql
-- Nightly delete-detection (soft-delete) reconcile, staggered per entity so each
-- stays within the edge function's wall-clock. Auth via public anon key.

do $$
declare
  auth text := 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imt6Y21zc2xkdnRqbmJ3d3VudXdtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzgwNTExMTIsImV4cCI6MjA5MzYyNzExMn0.ptlngXNjvjlEvAhPCiLGFvbRT7nA0zfr4MW-gqtPYRk';
  fn text := 'https://kzcmssldvtjnbwwunuwm.supabase.co/functions/v1/recruitcrm-sync?mode=reconcile&entity=';
begin
  perform cron.schedule('recruitcrm-reconcile-consultants', '0 3 * * *', format(
    $q$select net.http_post(url:=%L, headers:=jsonb_build_object('Authorization',%L,'Content-Type','application/json'), body:='{}'::jsonb, timeout_milliseconds:=55000);$q$,
    fn||'consultants', auth));
  perform cron.schedule('recruitcrm-reconcile-clients', '10 3 * * *', format(
    $q$select net.http_post(url:=%L, headers:=jsonb_build_object('Authorization',%L,'Content-Type','application/json'), body:='{}'::jsonb, timeout_milliseconds:=55000);$q$,
    fn||'clients', auth));
  perform cron.schedule('recruitcrm-reconcile-jobs', '20 3 * * *', format(
    $q$select net.http_post(url:=%L, headers:=jsonb_build_object('Authorization',%L,'Content-Type','application/json'), body:='{}'::jsonb, timeout_milliseconds:=55000);$q$,
    fn||'jobs', auth));
end $$;
