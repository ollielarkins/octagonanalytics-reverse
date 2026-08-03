-- 0001_structural_fixes.sql
-- Milestone 1 structural corrections that do NOT depend on the semantic-layer
-- decisions (D1–D5). Safe to apply now while all tables are empty.
-- Covers: jobs.slug, RLS + read policies on every table, stage lookup,
-- reporting-exclusions table, and an audit-log stub.

-- ── D3/D7 support: jobs.slug (deals.job_slug & candidate_stage_events.job_slug
--    reference jobs by slug; the column was missing) ────────────────────────────
alter table public.jobs add column if not exists slug text;
create unique index if not exists jobs_slug_key on public.jobs (slug);

-- ── Lookup: RecruitCRM integer stage id → canonical metric + display name (D2) ──
create table if not exists public.stage_lookup (
  recruitcrm_stage_id integer primary key,
  stage_metric        text not null,   -- canonical machine token, e.g. 'cv_sent'
  stage_name          text not null,   -- display, e.g. 'CV Sent'
  sort_order          integer,
  created_at          timestamptz default now()
);
comment on table public.stage_lookup is
  'Maps RecruitCRM integer stage IDs to the canonical stage_metric (machine) and stage_name (display). Populate from RecruitCRM once the token exists.';

-- ── Reporting exclusions in data, not hardcoded SQL (D3) ────────────────────────
create table if not exists public.reporting_exclusions (
  consultant_name text primary key,
  reason          text,
  created_at      timestamptz default now()
);
insert into public.reporting_exclusions (consultant_name, reason) values
  ('Laura',   'Pre-existing exclusion from consultant productivity reporting — CONFIRM'),
  ('Matthew', 'Pre-existing exclusion from consultant productivity reporting — CONFIRM'),
  ('Aimee',   'Pre-existing exclusion from consultant productivity reporting — CONFIRM')
on conflict (consultant_name) do nothing;

-- ── Audit-log stub for future Claude write-back (M6) ────────────────────────────
create table if not exists public.audit_log (
  id         uuid primary key default gen_random_uuid(),
  actor      text,                       -- recruiter who confirmed the action
  action     text not null,              -- e.g. 'update_hiring_stage'
  entity     text,                       -- e.g. 'candidate'
  entity_id  text,
  before     jsonb,
  after      jsonb,
  via        text default 'claude',
  created_at timestamptz default now()
);
comment on table public.audit_log is
  'Append-only audit of side-effectful actions taken via Claude (M6). Written by the mediation server (service role) only.';

-- ── RLS: enable everywhere + "authenticated can read all rows" (D6) ─────────────
-- Model: all recruiters see all data. Reads = authenticated. Writes happen via
-- the sync/mediation server using the service role, which bypasses RLS — so no
-- write policies are granted to authenticated. anon gets nothing (candidate PII).

alter table public.deal_stage_events enable row level security;  -- was DISABLED

do $$
declare t text;
begin
  foreach t in array array[
    'consultants','clients','jobs','placements','deals','daily_activity',
    'deal_stage_events','candidate_stage_events','stage_lookup',
    'reporting_exclusions','audit_log'
  ] loop
    execute format('alter table public.%I enable row level security;', t);
    execute format('drop policy if exists %I on public.%I;', t||'_authenticated_read', t);
    execute format(
      'create policy %I on public.%I for select to authenticated using (true);',
      t||'_authenticated_read', t
    );
  end loop;
end $$;
