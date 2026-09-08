-- 0072_digest_email_schedules.sql
-- Schedules for the three email digests.
--
-- pg_cron runs on the database clock, which is UTC. The recruiter reads these on London time, and
-- London is UTC+1 for about seven months of the year. A fixed UTC cron would therefore deliver the
-- "07:30" brief at 08:30 all summer, and silently correct itself in October - the kind of drift
-- nobody reports and everybody quietly works around.
--
-- So each job fires at BOTH candidate UTC hours and send_digest_if_due() drops the one that is not
-- the intended London hour. Exactly one fires per day, year round, with no DST maintenance.

-- The bearer the other crons already carry inline. Lifted from an existing job rather than pasted
-- in, so this migration contains no key material of its own and stays correct if the key rotates
-- and the other jobs are updated first. It is the publishable anon key, already in plaintext in
-- cron.job.command, so nothing is newly exposed - but keeping it in one place means the next
-- rotation is a single UPDATE rather than a hunt through every scheduled command.
insert into public.app_settings (key, value)
select 'cron_bearer', (regexp_match(command, 'Bearer ([A-Za-z0-9_.\-]+)'))[1]
from cron.job where jobname = 'recruitcrm-incremental-sync'
  and (regexp_match(command, 'Bearer ([A-Za-z0-9_.\-]+)'))[1] is not null
on conflict (key) do nothing;

create or replace function public.send_digest_if_due(p_kind text, p_london_hour integer)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  hdrs jsonb;
begin
  -- The gate. Cron fires twice; only the run matching London local time proceeds.
  if extract(hour from (now() at time zone 'Europe/London'))::int <> p_london_hour then
    return;
  end if;

  select jsonb_build_object('Authorization', 'Bearer ' || value, 'Content-Type', 'application/json')
    into hdrs from app_settings where key = 'cron_bearer';

  if hdrs is null then
    raise warning 'send_digest_if_due: app_settings.cron_bearer not set, digest % skipped', p_kind;
    return;
  end if;

  perform net.http_post(
    url := 'https://kzcmssldvtjnbwwunuwm.supabase.co/functions/v1/digest-email?kind=' || p_kind,
    headers := hdrs,
    body := '{}'::jsonb
  );
end;
$function$;

revoke all on function public.send_digest_if_due(text, integer) from public, anon, authenticated;

-- 07:30 London, Mon-Fri. Fires 06:30 and 07:30 UTC; the gate keeps one.
select cron.schedule('digest-morning', '30 6,7 * * 1-5',
  $$select public.send_digest_if_due('morning', 7);$$);

-- 17:30 London, Mon-Fri.
select cron.schedule('digest-evening', '30 16,17 * * 1-5',
  $$select public.send_digest_if_due('evening', 17);$$);

-- 08:00 London, Monday.
select cron.schedule('digest-weekly', '0 7,8 * * 1',
  $$select public.send_digest_if_due('weekly', 8);$$);

comment on function public.send_digest_if_due(text, integer) is
  'Fires a digest only when London local time matches p_london_hour. Each digest cron is scheduled at both possible UTC hours so BST/GMT never shifts delivery.';
