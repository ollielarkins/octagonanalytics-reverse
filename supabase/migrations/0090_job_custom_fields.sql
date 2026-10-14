-- Job custom fields in the mirror, for DPE and Push & Tell.
--
-- The DPE scores (Urgency, Cooperation, Track record, Commitment, Process Quality, Positioning),
-- Total Score, Job Grade, Findability and the Client Briefing Call / DPE Sent / Push & Tell Email
-- dates all live in RecruitCRM job custom fields. The mirror kept only forecast_fee from them, so
-- nothing could read a job's grade or when its DPE went out.
--
-- Stored as { "<field_id>": { "name": ..., "value": ... } }: keyed by RecruitCRM's field_id, which
-- survives a label being renamed in RecruitCRM; the name rides along for readability. Field
-- definitions (types, dropdown options) are NOT stored - read them live via
-- reference_list kind=job_custom_fields.
alter table public.jobs add column if not exists custom_fields jsonb;

comment on column public.jobs.custom_fields is
  'RecruitCRM job custom fields keyed by field_id: {"<id>": {"name": ..., "value": ...}}. DPE ids: 45-50 scores, 51 Total Score, 13 Job Grade, 52 Findability, 4 Client Briefing Call, 41 DPE Sent, 44 Push & Tell Email.';

-- Job Grade drives the Push & Tell job list; index the lookup.
create index if not exists jobs_job_grade_idx on public.jobs ((custom_fields->'13'->>'value'));
