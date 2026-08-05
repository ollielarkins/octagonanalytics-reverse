-- 0032_webhook_events.sql
-- Observability log for the recruitcrm-webhook receiver. Each inbound RecruitCRM webhook is logged
-- here (raw payload + what we routed it to) so we can confirm payload shapes and debug freshness.
-- The webhook itself is a "something changed -> run incremental now" trigger; this table is the audit.

create table if not exists public.webhook_events (
  id            bigint generated always as identity primary key,
  received_at   timestamptz not null default now(),
  source        text not null default 'recruitcrm',
  event_hint    text,          -- best-effort event/entity guess from the payload
  routed_entity text,          -- entity we fired the incremental sync for (or 'all')
  raw           jsonb,         -- the raw webhook body
  ok            boolean
);
create index if not exists webhook_events_received_idx on public.webhook_events (received_at desc);
alter table public.webhook_events enable row level security;
-- service-role only (the receiver uses the service key); no anon/authenticated access.
revoke all on public.webhook_events from anon, authenticated;
