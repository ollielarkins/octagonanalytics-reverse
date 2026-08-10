-- 0048_feedback.sql
-- Issues / feedback / feature requests submitted from the connect page.
--
-- Stored first, notified second. Notification is best-effort (Slack webhook now, email once an
-- provider key exists) so a delivery failure can never lose the submission — the row is the record.
create table if not exists public.feedback (
  id                       uuid primary key default gen_random_uuid(),
  created_at               timestamptz not null default now(),
  kind                     text not null check (kind in ('issue','feedback','feature')),
  message                  text not null check (length(message) between 1 and 4000),
  from_name                text,
  from_email               text,
  consultant_recruitcrm_id bigint,
  user_agent               text,
  source                   text,
  emailed                  boolean not null default false,
  slacked                  boolean not null default false,
  handled_at               timestamptz
);
create index if not exists feedback_created_idx on public.feedback (created_at desc);
create index if not exists feedback_open_idx on public.feedback (created_at desc) where handled_at is null;

alter table public.feedback enable row level security;
revoke all on public.feedback from anon, authenticated;
