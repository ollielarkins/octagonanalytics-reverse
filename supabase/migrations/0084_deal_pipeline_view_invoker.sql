-- 0084_deal_pipeline_view_invoker.sql
-- 0002 created deal_pipeline_by_stage with security_invoker = on. 0075 re-created it with a plain
-- CREATE OR REPLACE VIEW, which resets the view's options, so it silently became SECURITY DEFINER:
-- it ran as postgres, bypassed RLS on deals, and anon holds SELECT on it - open pipeline totals by
-- stage were readable with the public anon key. Nothing reads this view (no function, view or
-- edge function references it), so restoring invoker semantics breaks nothing.
--
-- Any future CREATE OR REPLACE of this view must repeat WITH (security_invoker = on).
alter view public.deal_pipeline_by_stage set (security_invoker = on);
