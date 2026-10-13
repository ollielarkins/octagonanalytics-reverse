-- 0085_inbox.sql
-- Per-recruiter Outlook inbox: the platform checks each connected mailbox every 5 minutes, tells the
-- recruiter in chat what has arrived, and drafts replies into their Outlook Drafts on request.
--
-- Data minimisation is the design constraint. Only envelope metadata is stored (sender, subject,
-- time, thread) plus a rule-based category. Bodies are never stored: they are fetched live from
-- Microsoft Graph when the recruiter asks to read one, and used transiently for classification.
-- Rows older than 30 days are purged daily.
--
-- A mailbox is polled only once its owner connects it (inbox action=connect, preview + confirm), so
-- nobody's mail is read because they happen to hold a token. Microsoft's side is restricted
-- separately: the Graph app may only touch mailboxes in the scoping group the M365 admin manages.

create table if not exists public.inbox_mailboxes (
  consultant_recruitcrm_id bigint primary key,   -- = mcp_tokens.consultant_recruitcrm_id (0 = admin sentinel)
  mailbox        text not null,                  -- the user's @octagongroup.co.uk address
  enabled        boolean not null default true,
  delta_link     text,                           -- Graph delta cursor for the Inbox folder
  last_seen_at   timestamptz,                    -- when the owner last listed their inbox in chat
  last_run_at    timestamptz,
  last_status    text,
  created_at     timestamptz not null default now()
);
alter table public.inbox_mailboxes enable row level security;
revoke all on table public.inbox_mailboxes from public, anon, authenticated;

create table if not exists public.inbox_messages (
  id               text primary key,             -- Graph message id
  consultant_recruitcrm_id bigint not null references public.inbox_mailboxes(consultant_recruitcrm_id) on delete cascade,
  conversation_id  text,
  from_name        text,
  from_address     text,
  subject          text,
  received_at      timestamptz not null,
  importance       text,
  is_read          boolean,
  focused          boolean,                      -- Outlook's Focused/Other split
  category         text not null,                -- routine | never | other | automated
  reason           text,                         -- which rule decided the category
  created_at       timestamptz not null default now()
);
create index if not exists inbox_messages_owner_received on public.inbox_messages (consultant_recruitcrm_id, received_at desc);
alter table public.inbox_messages enable row level security;
revoke all on table public.inbox_messages from public, anon, authenticated;

-- Poll every 5 minutes. The bearer is read at run time from app_settings, as send_digest_if_due does,
-- so the key is not copied into the job text.
select cron.schedule('inbox-poll', '*/5 * * * *', $job$
  select net.http_post(
    url := 'https://kzcmssldvtjnbwwunuwm.supabase.co/functions/v1/inbox-sync',
    headers := (select jsonb_build_object('Authorization', 'Bearer ' || value, 'Content-Type', 'application/json')
                  from public.app_settings where key = 'cron_bearer'),
    body := '{}'::jsonb,
    timeout_milliseconds := 55000);
$job$);

select cron.schedule('inbox-retention', '20 3 * * *', $job$
  delete from public.inbox_messages where received_at < now() - interval '30 days';
$job$);

insert into public.cron_manifest (jobname, schedule, note) values
  ('inbox-poll',      '*/5 * * * *', 'checks connected Outlook inboxes via Graph (0085)'),
  ('inbox-retention', '20 3 * * *',  'purges inbox metadata older than 30 days (0085)')
on conflict (jobname) do update set schedule = excluded.schedule, note = excluded.note;

-- Not registered in sync_health() yet: until the Graph secrets are set every run reports
-- not_configured, which would alert. Add ('inbox','live',15,45,false) to its cfg list once live.
