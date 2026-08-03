-- 0008_candidates_and_stage_lookup.sql
-- Phase 2 foundations: a candidates dimension (the iteration source for the
-- hiring-stage-history backfill) and the confirmed stage-id → metric mapping.

create table if not exists public.candidates (
  id                  uuid primary key default gen_random_uuid(),
  recruitcrm_id       bigint unique,
  slug                text unique,
  first_name          text,
  last_name           text,
  name                text,
  email               text,
  owner_recruitcrm_id bigint,
  city                text,
  country             text,
  source              text,
  created_date        timestamp,
  updated_date        timestamp,
  deleted_at          timestamptz,
  created_at          timestamptz default now()
);

alter table public.candidates enable row level security;
drop policy if exists candidates_authenticated_read on public.candidates;
create policy candidates_authenticated_read on public.candidates
  for select to authenticated using (true);

-- Confirmed hiring-stage mapping (real RecruitCRM account status_ids → canonical
-- funnel metric). Verified from live /history + the hand-import + ratios sheet.
-- Assigned (id 1) and any other statuses are intentionally NOT funnel metrics.
insert into public.stage_lookup (recruitcrm_stage_id, stage_metric, stage_name, sort_order) values
  (390955, 'cv_sent',              'CV Sent',              1),
  (381800, 'interview_request',    'Interview Request',    2),
  (381799, 'first_interview',      '1st Interview',        3),
  (381801, 'second_interview',     '2nd Interview',        4),
  (381805, 'offered',              'Offered',              5),
  (8,      'placed',               'Placed',               6),
  (381802, 'rejected_client',      'Rejected - Client',    90),
  (481042, 'rejected_consultant',  'Rejected - Consultant',91)
on conflict (recruitcrm_stage_id) do update
  set stage_metric = excluded.stage_metric,
      stage_name   = excluded.stage_name,
      sort_order   = excluded.sort_order;
