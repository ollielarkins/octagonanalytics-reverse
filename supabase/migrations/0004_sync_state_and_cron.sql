-- 0004_sync_state_and_cron.sql
-- "Stay live": incremental-sync cursor + scheduling infrastructure.

-- Scheduling extensions (Supabase-managed)
create extension if not exists pg_cron;
create extension if not exists pg_net;

-- Per-entity incremental cursor. The sync reads records sorted updatedon desc
-- and stops once it reaches last_synced_at, so each run only pulls the changed tail.
create table if not exists public.sync_state (
  entity         text primary key,
  last_synced_at timestamptz,
  last_run_at    timestamptz,
  last_status    text
);

-- Seed with now(): we just completed the full backfill, so the first incremental
-- run should only pick up changes made after this point.
insert into public.sync_state (entity, last_synced_at) values
  ('consultants', now()), ('clients', now()), ('jobs', now())
on conflict (entity) do nothing;

alter table public.sync_state enable row level security;
drop policy if exists sync_state_authenticated_read on public.sync_state;
create policy sync_state_authenticated_read on public.sync_state
  for select to authenticated using (true);

-- The scheduled cron job itself is created in the next step (needs the function
-- URL + anon-key auth header); see 0005.
