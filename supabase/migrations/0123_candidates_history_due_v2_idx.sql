-- 0123_candidates_history_due_v2_idx.sql
-- The candidates sync hit Postgres statement timeouts (57014) on 25-28/10/2026. The history-recent
-- walk looks for candidates changed since their stage history was last walked; 0058's index covered
-- only updated_date, so the history_walked_at filter still read every row. The v2 index is partial
-- on exactly that filter, so it holds only the candidates still due (16 kB against 8,224 kB).
--
-- APPLIED BY HAND on 28/10/2026: v2 created at 09:54 UTC, the 0058 index dropped at about 10:12 UTC
-- (7 scans ever, last on 14/10/2026). This file records it; do not re-run it on production.
-- Both statements are CONCURRENTLY, so they cannot run inside a transaction block: run them one at a
-- time, outside a migration transaction, if this is ever replayed.

create index concurrently if not exists candidates_history_due_v2_idx
  on public.candidates (updated_date desc nulls last)
  where slug is not null and (history_walked_at is null or history_walked_at < updated_date);

drop index concurrently if exists public.candidates_history_due_idx;
