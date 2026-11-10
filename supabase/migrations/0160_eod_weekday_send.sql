-- 0160_eod_weekday_send.sql
-- The end-of-day stats email (digest-email?kind=eod), sent to Dale every weekday at 15:30 London.
--
-- NOT APPLIED on 10/11/2026: the org instructions then allowed only the Friday EOW email to be sent
-- automatically. Apply only once they also allow this one. Until then eod_sends does not exist, so
-- a non-dry call to kind=eod fails at the claim and never reaches Resend.
--
-- After applying, set the recipient by hand (kept out of this public repo):
--   insert into public.app_settings (key, value) values ('eod_to_email', '<address>')
--   on conflict (key) do update set value = excluded.value;

-- One row per day; claimed before sending, released if Resend refuses (same pattern as eow_sends).
create table if not exists public.eod_sends (
  day         date primary key,
  status      text not null check (status in ('sending', 'sent')),
  resend_id   text,
  claimed_at  timestamptz not null default now(),
  sent_at     timestamptz
);
alter table public.eod_sends enable row level security;
revoke all on table public.eod_sends from anon, authenticated;

comment on table public.eod_sends is
  'One row per weekday the 15:30 end-of-day stats email was sent to Dale (digest-email kind=eod). Guards against double sends.';

-- 15:30 London, Mon-Fri. Fires 14:30 and 15:30 UTC; send_digest_if_due keeps the one at London hour 15.
select cron.unschedule('digest-eod') where exists (select 1 from cron.job where jobname = 'digest-eod');
select cron.schedule('digest-eod', '30 14,15 * * 1-5',
  $$select public.send_digest_if_due('eod', 15);$$);
