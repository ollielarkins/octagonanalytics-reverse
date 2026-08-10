-- 0041_jobs_company_slug.sql
-- 2,410 of 5,975 jobs (40.3%) have client_id null. Root cause: mapJobFactory resolves
-- clientBySlug.get(job.company_slug) at write time and stores ONLY the resolved uuid — if the
-- company isn't in `clients` (archived in RecruitCRM, so the companies list endpoint never returns
-- it) the link is discarded and the job is orphaned with no way back. The API does send
-- company_slug on every job; we were throwing it away.
--
-- Persist it. That alone makes the orphans countable and groupable, and lets a later backfill
-- fetch those companies individually by slug and resolve client_id retrospectively.
-- Existing rows stay null until they are re-upserted by a jobs backfill.
alter table public.jobs add column if not exists company_slug text;
create index if not exists jobs_company_slug_idx on public.jobs (company_slug) where client_id is null;
