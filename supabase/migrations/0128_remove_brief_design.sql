-- 0128_remove_brief_design.sql
-- 28/10/2026: the redesigned team briefs were tried and dropped; the briefs stay as post_digest sends
-- them. This removes the unused pieces that were applied while testing (0127, applied straight to production and never merged): digest_blocks() and its two
-- helpers. Nothing else used them and no scheduled job called them.
drop function if exists public.digest_blocks(text);
drop function if exists public.slack_field_blocks(jsonb);
drop function if exists public.slack_bar(numeric, numeric, integer);
