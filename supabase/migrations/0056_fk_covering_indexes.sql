-- 0056_fk_covering_indexes.sql
-- Five foreign keys had no covering index (Supabase performance advisor, 0001_unindexed_foreign_keys).
--
-- jobs.client_id and jobs.consultant_id are the two that actually cost us: every per-consultant
-- dashboard, the funnel breakdown and client_report join through them. placements carries the same
-- gap on all three of its keys.
--
-- Built without CONCURRENTLY on purpose: a migration runs in a transaction, and at 5,993 jobs and a
-- few hundred placements these build in milliseconds. Revisit only if either table grows an order
-- of magnitude.

create index if not exists jobs_client_id_idx            on public.jobs(client_id);
create index if not exists jobs_consultant_id_idx        on public.jobs(consultant_id);
create index if not exists placements_client_id_idx      on public.placements(client_id);
create index if not exists placements_consultant_id_idx  on public.placements(consultant_id);
create index if not exists placements_job_id_idx         on public.placements(job_id);
