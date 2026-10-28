-- 0125_queue_message_blocks.sql
-- Requested 28/10/2026: when a consultant presses Done in the 08:30 queue DM and confirms, the button
-- changes to "Completed" so they can see it registered. Presses are still recorded in
-- action_queue_done; an item already done shows "Completed" whenever the message is redrawn.
--
-- Slack's chat.update replaces the whole message, so slack-actions needs the message's current
-- blocks. The bot has no im:history scope to read its own DM back, so slack-actions keeps the latest
-- blocks here: saved when Done is pressed (Slack sends the message as it stands), rewritten after
-- each update, so Completed buttons accumulate instead of being lost on the next press.

create table if not exists public.slack_queue_messages (
  channel_id text not null,
  message_ts text not null,
  blocks     jsonb not null,
  updated_at timestamptz not null default now(),
  primary key (channel_id, message_ts)
);
alter table public.slack_queue_messages enable row level security;
revoke all on table public.slack_queue_messages from anon, authenticated;
