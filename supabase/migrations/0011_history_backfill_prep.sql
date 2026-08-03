-- 0011_history_backfill_prep.sql
-- Prep for the hiring-stage history backfill into candidate_stage_events.

-- Resumable cursor (last processed candidate recruitcrm_id) for the 'history' job.
alter table public.sync_state add column if not exists cursor text;

-- SSOT (D8): the hand-imported candidate_stage_events (1,071 rows, stale/sparse,
-- no pre-2026 data) is replaced by the authoritative RecruitCRM history (full,
-- back to 2023). Clear it so the rebuild is clean and idempotent.
truncate table public.candidate_stage_events;

-- Idempotency key so the backfill (and go-forward) can upsert safely.
create unique index if not exists cse_natural_key
  on public.candidate_stage_events (candidate_slug, job_slug, stage_metric, event_timestamp);

-- Seed / reset the history-backfill cursor.
insert into public.sync_state (entity, cursor, last_status)
values ('history', '0', 'pending')
on conflict (entity) do update set cursor = '0', last_status = 'pending';
