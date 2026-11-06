-- 0155_one_claude_deals_definition.sql
-- 06/11/2026: one definition of what Claude contributed to deals.
-- 0154's claude_attribution() and 0150's claude_deals() were built in parallel on 05/11/2026 and
-- disagreed. This quarter, 0154 credited "£20,200 Claude-assisted"; claude_deals counts the same
-- deal as recorded (Claude made a stage move, i.e. admin) and £0 as sourced. claude_deals is kept:
-- it separates finding from admin, and uses the /match suggestion log.
--   - The Friday usage post's line now comes from claude_deals over its default window (Claude work
--     since 01/08/2026), so it matches /claudedeals.
--   - usage_report() no longer returns a claude_attribution block.
--   - claude_attribution() is no longer called. Dropping it was declined by the migration
--     approval, so it still exists, unused: drop it by hand with
--     drop function public.claude_attribution(date, date, text);

do $do$
declare src text;
begin
  src := pg_get_functiondef('public.usage_report'::regproc);
  src := replace(src, E'  res := res || jsonb_build_object(''claude_attribution'', public.claude_attribution(p_from, p_to, p_consultant));\n', '');
  if position('claude_attribution' in src) > 0 then
    raise exception 'usage_report: attribution line not found, nothing changed';
  end if;
  execute src;

  src := pg_get_functiondef('public.weekly_usage_post'::regproc);
  src := regexp_replace(src,
    'public\.slack_section\(''\*Claude-assisted fees this quarter\*''.*?from \(select public\.claude_attribution\([^;]*?\) a\) q\)\),',
    $r$public.slack_section('*Claude''s part in deals, since 01/08/2026*'||E'\n'||(select
        'Found by Claude: '||(d->'sourced'->>'pairs')||' candidates put on jobs, '||coalesce(d->'sourced'->'reached'->>'cv_sent', '0')||' reached CV Sent, '
        ||coalesce(d->'sourced'->'reached'->>'offered', '0')||' Offered (£'||to_char(coalesce((d->'sourced'->>'offered_value')::numeric, 0), 'FM999,999,990')||' pipeline), '
        ||coalesce(d->'sourced'->'reached'->>'placed', '0')||' Placed (£'||to_char(coalesce((d->'sourced'->>'won_value')::numeric, 0), 'FM999,999,990')||' Won).'
        ||E'\n'||'Admin recorded through Claude: '||(d->'recorded'->>'pairs')||' stage moves, £'||to_char(coalesce((d->'recorded'->>'won_value')::numeric, 0), 'FM999,999,990')||' Won. Detail: /claudedeals.'
        from (select public.claude_deals(null, null, null) d) q)),$r$, 's');
  if position('claude_attribution' in src) > 0 or position('claude_deals' in src) = 0 then
    raise exception 'weekly_usage_post: attribution block not replaced, nothing changed';
  end if;
  execute src;
end
$do$;
