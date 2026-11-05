-- 0150_coach_live_briefs_retired.sql
-- The Octagon Coach goes live and the Team Briefs are retired (decided 04/11/2026), in two steps:
--   05/11/2026 06:00 UK  coach out of shadow mode for Bhavesh Patel, Will Drake and Keelan Riley.
--                        Adam Barnett comes off the pilot for this week. Team Briefs all stop: the
--                        #briefs morning, day-end and weekly digests, the 08:30 action queue DMs, and
--                        the Monday manager exceptions DM (sent from the same daily-queue run).
--   09/11/2026 06:00 UK  Adam Barnett (77603) and Dale Barnett (77604) join, before the 08:45
--                        Monday week-ahead DM.
-- Each step is a one-off cron job that removes itself after it runs.
-- Kept on purpose: the post_digest/action_queue functions, the daily-queue and slack-actions edge
-- functions (Done buttons on queue DMs already sent still write back), and the digest webhook that
-- /digest uses on demand. Bringing a brief back is a cron.schedule call plus its cron_manifest row.

create or replace function public.coach_go_live_0150()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  j text;
  removed text[] := '{}';
begin
  if (now() at time zone 'Europe/London')::date < date '2026-11-05' then
    return jsonb_build_object('skipped', 'before 05/11/2026');
  end if;

  update app_settings set value = '154036,77535,65639', updated_at = now()
   where key = 'coach_pilot';   -- Will Drake, Keelan Riley, Bhavesh Patel
  update app_settings set value = 'false', updated_at = now()
   where key = 'coach_shadow';

  -- Out of the manifest first, so the watchdog does not alert on the jobs going.
  delete from cron_manifest
   where jobname in ('digest-slack-morning', 'digest-slack-evening', 'digest-slack-weekly', 'daily-action-queue');

  foreach j in array array['digest-slack-morning', 'digest-slack-evening', 'digest-slack-weekly', 'daily-action-queue'] loop
    if exists (select 1 from cron.job where jobname = j) then
      perform cron.unschedule(j);
      removed := removed || j;
    end if;
  end loop;

  if exists (select 1 from cron.job where jobname = 'coach-go-live-0150') then
    perform cron.unschedule('coach-go-live-0150');
  end if;

  return jsonb_build_object('coach_shadow', false, 'coach_pilot', 3, 'unscheduled', removed);
end $fn$;

create or replace function public.coach_add_wave2_0150()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
begin
  if (now() at time zone 'Europe/London')::date < date '2026-11-09' then
    return jsonb_build_object('skipped', 'before 09/11/2026');
  end if;

  update app_settings set value = '154036,77535,65639,77603,77604', updated_at = now()
   where key = 'coach_pilot';   -- + Adam Barnett, Dale Barnett

  if exists (select 1 from cron.job where jobname = 'coach-wave2-0150') then
    perform cron.unschedule('coach-wave2-0150');
  end if;

  return jsonb_build_object('coach_pilot', 5);
end $fn$;

revoke all on function public.coach_go_live_0150() from public, anon, authenticated;
revoke all on function public.coach_add_wave2_0150() from public, anon, authenticated;
grant execute on function public.coach_go_live_0150() to service_role;
grant execute on function public.coach_add_wave2_0150() to service_role;

-- 06:00 UTC = 06:00 UK in November (GMT).
select cron.schedule('coach-go-live-0150', '0 6 5 11 *', $$select public.coach_go_live_0150();$$);
select cron.schedule('coach-wave2-0150',   '0 6 9 11 *', $$select public.coach_add_wave2_0150();$$);
