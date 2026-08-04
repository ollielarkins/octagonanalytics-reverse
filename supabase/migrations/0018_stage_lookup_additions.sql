-- 0018_stage_lookup_additions.sql
-- Discovery (2026-08-04) pulled all 3 hiring-pipeline definitions from RecruitCRM.
-- There is NO "Internal Interview" stage anywhere. Two REAL stages were unmapped and
-- therefore being DROPPED by the history sync / write-through (which skip unknown ids):
--   * 3rd Interview  (394846)
--   * Shortlist      (511685)  — a pre-CV stage, like Assigned/Applied
-- Mapping them here stops the data loss. NOTE: historical 3rd-Interview / Shortlist
-- events won't appear until a history resync re-pulls candidate history with this
-- expanded lookup; future write-throughs pick them up immediately.

insert into public.stage_lookup (recruitcrm_stage_id, stage_metric, stage_name) values
  (394846, 'third_interview', '3rd Interview'),
  (511685, 'shortlist',       'Shortlist')
on conflict (recruitcrm_stage_id) do update
  set stage_metric = excluded.stage_metric, stage_name = excluded.stage_name;
