-- 0000_baseline_tables.sql
-- Baseline reconstruction of the hand-built schema as found on the live project
-- "Reporting for CRM" (ref kzcmssldvtjnbwwunuwm) on 2026-08-03.
--
-- WHY THIS EXISTS: the project had NO migration history — the 8 tables and 19
-- analytics views were built by hand in the SQL editor. This file captures the
-- table shapes as-found so the schema is reproducible and every later change is
-- a reviewable diff. The 19 legacy views are captured separately (see the
-- canonical-rebuild migration) before they are replaced.
--
-- NOTE: This is a faithful RECONSTRUCTION from the live catalog (columns, types,
-- defaults, PKs, FKs, unique constraints), not a byte-for-byte pg_dump. All
-- tables were empty (0 rows) when captured. It is idempotent-ish (IF NOT EXISTS)
-- so it is safe to record as the baseline without recreating existing objects.

create extension if not exists pgcrypto;  -- gen_random_uuid()

-- ── Relational core ──────────────────────────────────────────────────────────

create table if not exists public.consultants (
  id             uuid primary key default gen_random_uuid(),
  recruitcrm_id  bigint unique,
  name           text,
  email          text,
  team           text,
  active         boolean default true,
  created_at     timestamp default now()
);

create table if not exists public.clients (
  id             uuid primary key default gen_random_uuid(),
  recruitcrm_id  bigint unique,
  company_name   text,
  industry       text,
  country        text,
  client_type    text,
  active         boolean default true,
  created_at     timestamp default now(),
  company_slug   text unique
);

create table if not exists public.jobs (
  id              uuid primary key default gen_random_uuid(),
  recruitcrm_id   bigint unique,
  title           text,
  client_id       uuid references public.clients(id),
  consultant_id   uuid references public.consultants(id),
  status          text,
  employment_type text,
  salary_min      numeric,
  salary_max      numeric,
  created_date    timestamp,
  closed_date     timestamp
  -- NOTE: no `slug` column — added in the corrective migration (deals.job_slug
  -- and candidate_stage_events.job_slug reference jobs by slug).
);

create table if not exists public.placements (
  id             uuid primary key default gen_random_uuid(),
  recruitcrm_id  bigint unique,
  job_id         uuid references public.jobs(id),
  consultant_id  uuid references public.consultants(id),
  client_id      uuid references public.clients(id),
  candidate_name text,
  placement_type text,
  fee_amount     numeric,
  placement_date timestamp,
  source         text,
  created_at     timestamp default now()
);

-- ── Event / activity tables (slug/name-referenced, flatter) ─────────────────────

create table if not exists public.deals (
  id                  uuid primary key default gen_random_uuid(),
  recruitcrm_id       bigint unique,
  deal_name           text,
  deal_stage          text,
  deal_value          numeric,
  close_date          timestamp,
  deal_type           text,
  company_slug        text,
  job_slug            text,
  owner_recruitcrm_id bigint,
  created_date        timestamp,
  updated_date        timestamp,
  resource_url        text,
  created_at          timestamp default now()
);

create table if not exists public.daily_activity (
  id                      uuid primary key default gen_random_uuid(),
  activity_date           date,
  consultant              text,
  tasks_added             integer default 0,
  jobs_added              integer default 0,
  assigned                integer default 0,
  cv_sent                 integer default 0,
  interview_request       integer default 0,
  first_interview         integer default 0,
  second_interview        integer default 0,
  offered                 integer default 0,
  prospect_bd             integer default 0,
  client                  integer default 0,
  internal_interview      integer default 0,
  job_order_form_complete integer default 0,
  lead                    integer default 0,
  pitched                 integer default 0,
  call_time_minutes       integer default 0,
  created_at              timestamp default now()
);

create table if not exists public.deal_stage_events (
  id                 uuid primary key default gen_random_uuid(),
  recruitcrm_deal_id bigint,
  internal_deal_id   bigint,
  stage_name         text,
  stage_metric       text,
  consultant_id      bigint,
  consultant         text,
  event_date         date,
  event_timestamp    timestamp,
  created_at         timestamp default now()
);

create table if not exists public.candidate_stage_events (
  id              uuid primary key default gen_random_uuid(),
  job_id          bigint,
  job_slug        text,
  candidate_id    bigint,
  candidate_slug  text,
  consultant_id   bigint,
  consultant      text,
  stage_name      text,
  stage_metric    text,
  event_date      date,
  event_timestamp timestamp,
  created_at      timestamp default now(),
  candidate_name  text,
  job_title       text
);

-- RLS state as-found (corrected in the next migration):
--   * 7 tables had RLS ENABLED but with ZERO policies (deny-all on direct access).
--   * public.deal_stage_events had RLS DISABLED (wide open via the anon key).
-- Left as-found here on purpose; 0001 fixes it.
