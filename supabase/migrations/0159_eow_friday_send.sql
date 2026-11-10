-- 0159_eow_friday_send.sql
-- The end-of-week team email, sent to Dale every Friday at 16:30 London via digest-email?kind=eow.
-- Dale reviews it, adds his comments and forwards it to the team. Replies and Push & Tell stay
-- drafts; only this email is sent automatically.
--
-- The recipient lives in app_settings.eow_to_email, set by hand, not here: this repo is public and
-- the address is personal data. digest-email reports sent:false while it is unset.

-- One row per week. digest-email claims the row before sending (insert on conflict do nothing) and
-- deletes it if Resend refuses, so a cron that fires twice or a manual re-run can never send the
-- same week twice, and a failed send can be retried.
create table if not exists public.eow_sends (
  week_start  date primary key,
  window_to   date,
  status      text not null check (status in ('sending', 'sent')),
  resend_id   text,
  claimed_at  timestamptz not null default now(),
  sent_at     timestamptz
);
-- Service role only: RLS on with no policies.
alter table public.eow_sends enable row level security;
revoke all on table public.eow_sends from anon, authenticated;

comment on table public.eow_sends is
  'One row per week the Friday EOW email was sent to Dale (digest-email kind=eow). Guards against double sends.';

-- 16:30 London, Friday. Fires 15:30 and 16:30 UTC; send_digest_if_due keeps the one at London hour 16.
select cron.unschedule('digest-eow') where exists (select 1 from cron.job where jobname = 'digest-eow');
select cron.schedule('digest-eow', '30 15,16 * * 5',
  $$select public.send_digest_if_due('eow', 16);$$);
