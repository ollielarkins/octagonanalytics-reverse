-- 0114_admin_bot_sync_only.sql
-- 26/10/2026: the analytics-admin Slack bot (the webhook into Oliver's DM) carries sync alerts only.
-- A Slack incoming webhook cannot be limited by Slack itself: whoever holds the URL can post. So the
-- limit is which settings hold that URL and which functions read them.
--
-- Before: the same URL sat in two settings. alert_webhook_url is read by the sync jobs
-- (check_sync_health, check_cron_manifest, sync_health_digest). admin_webhook_url was read by
-- post_admin_digest (not scheduled), the connect-page feedback function, and post_digest as a
-- fallback when digest_webhook_url was unset.
-- After: admin_webhook_url is removed, and post_digest no longer falls back. The briefs post only to
-- digest_webhook_url (#claude-teambriefs); with it unset they do not post at all. Feedback is still
-- saved to the feedback table, but no longer reaches Slack (one submission ever, on 10/08/2026).

-- post_digest: drop the admin_webhook_url fallback. Guarded: fail if the block has changed.
do $do$
declare
  def text := pg_get_functiondef('public.post_digest(text)'::regprocedure);
  fallback text := $a$  if hook is null then
    select value into hook from app_settings where key = 'admin_webhook_url' and coalesce(value,'') <> '';
  end if;
$a$;
begin
  if position('admin_webhook_url' in def) = 0 then
    return;   -- already applied
  end if;
  if (length(def) - length(replace(def, fallback, ''))) / length(fallback) <> 1 then
    raise exception '0114: post_digest fallback block not found exactly once; post_digest has changed since 26/10/2026';
  end if;
  def := replace(def, fallback, '');
  def := replace(def, $r$'no digest_webhook_url or admin_webhook_url set'$r$, $r$'no digest_webhook_url set'$r$);
  if position('admin_webhook_url' in def) > 0 then
    raise exception '0114: post_digest still mentions admin_webhook_url';
  end if;
  execute def;
end;
$do$;

-- The second copy of the admin bot's URL. Its value is identical to alert_webhook_url (checked
-- 26/10/2026), so nothing is lost: the sync jobs keep posting through alert_webhook_url.
do $do$
begin
  if exists (select 1 from app_settings a join app_settings b on b.key = 'alert_webhook_url'
             where a.key = 'admin_webhook_url' and a.value is distinct from b.value) then
    raise exception '0114: admin_webhook_url differs from alert_webhook_url; check before removing it';
  end if;
  delete from app_settings where key = 'admin_webhook_url';
end;
$do$;
