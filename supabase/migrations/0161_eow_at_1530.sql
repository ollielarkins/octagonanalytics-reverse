-- 0161_eow_at_1530.sql
-- The Friday end-of-week email to Dale moves from 16:30 to 15:30 London, matching the org rule.
-- On Fridays it now goes out alongside the 15:30 end-of-day email (0160).

-- 15:30 London, Friday. Fires 14:30 and 15:30 UTC; send_digest_if_due keeps the one at London hour 15.
select cron.unschedule('digest-eow') where exists (select 1 from cron.job where jobname = 'digest-eow');
select cron.schedule('digest-eow', '30 14,15 * * 5',
  $$select public.send_digest_if_due('eow', 15);$$);
