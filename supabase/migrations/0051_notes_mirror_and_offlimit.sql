-- 0051_notes_mirror_and_offlimit.sql
--
-- Two things, both discovered on 10/08/2026 while walking the API surface.
--
-- 1. NOTES MIRROR. Leads, internal interviews and "job order form complete" are recorded as NOTE
--    TYPES in RecruitCRM and have been all along, while this platform documented them as
--    "not tracked anywhere". They could not be counted because /notes/search filters by the record
--    a note hangs off, not by type, owner or date — there is no "how many leads this month" call.
--    Mirroring notes makes them countable the same way candidate_stage_events made the funnel
--    countable.
--
-- 2. OFF-LIMIT FLAGS. 88 candidates are marked do-not-approach in RecruitCRM and nothing here knew,
--    so match_candidates would happily shortlist them.
--
-- Note text is mirrored because for a Lead note the text IS the lead ("Senior Design Engineer -
-- AES Sheffield"). Same PII trust boundary as candidate_stage_events, which already stores names.

create table if not exists public.notes (
  recruitcrm_id            bigint primary key,
  note_type                text,
  description              text,
  related_to               text,
  related_to_type          text,
  consultant_recruitcrm_id bigint,
  created_on               timestamptz,
  updated_on               timestamptz,
  created_at               timestamptz not null default now()
);
create index if not exists notes_created_idx on public.notes (created_on desc);
create index if not exists notes_type_idx    on public.notes (note_type);
create index if not exists notes_cons_idx    on public.notes (consultant_recruitcrm_id);
alter table public.notes enable row level security;
revoke all on public.notes from anon, authenticated;

alter table public.candidates add column if not exists off_limit        boolean not null default false;
alter table public.candidates add column if not exists off_limit_until  date;
alter table public.candidates add column if not exists off_limit_reason text;
create index if not exists candidates_off_limit_idx on public.candidates (off_limit) where off_limit;

-- Counts of the note types that carry the previously "untracked" KPIs, by consultant and period.
-- Attributed to the note's author (created_by), like calls are to the caller.
create or replace function public.notes_kpi_report(
  p_from date default date_trunc('month', current_date)::date,
  p_to   date default '2100-01-01'::date,
  p_consultant text default null)
returns jsonb language sql stable security definer set search_path to 'public' as $function$
  with n as (
    select nt.note_type, co.name consultant, nt.created_on::date d, nt.description
    from notes nt
    left join consultants co on co.recruitcrm_id = nt.consultant_recruitcrm_id and co.deleted_at is null
    where nt.created_on >= p_from and nt.created_on < p_to
      and (p_consultant is null or co.name ilike '%'||p_consultant||'%')
  )
  select jsonb_build_object(
    'window', jsonb_build_object('from', p_from, 'to', p_to),
    'definition', 'Counts of RecruitCRM notes by type, attributed to the note author. The Lead, Candidate - Internal Interview and Job Order Form Complete types carry KPIs previously documented as untracked. Only notes actually logged appear here.',
    'headline', (select jsonb_build_object(
        'leads', count(*) filter (where note_type = 'Lead'),
        'internal_interviews', count(*) filter (where note_type = 'Candidate - Internal Interview'),
        'job_order_forms', count(*) filter (where note_type = 'Job Order Form Complete'),
        'all_notes', count(*)) from n),
    'by_type', (select coalesce(jsonb_agg(jsonb_build_object('type', coalesce(note_type,'(none)'), 'count', c) order by c desc), '[]'::jsonb)
      from (select note_type, count(*) c from n group by note_type) t),
    'by_consultant', (select coalesce(jsonb_agg(jsonb_build_object(
        'name', consultant,
        'leads', l, 'internal_interviews', ii, 'job_order_forms', jof, 'all_notes', tot) order by l desc, tot desc), '[]'::jsonb)
      from (select consultant,
              count(*) filter (where note_type='Lead') l,
              count(*) filter (where note_type='Candidate - Internal Interview') ii,
              count(*) filter (where note_type='Job Order Form Complete') jof,
              count(*) tot
            from n where consultant is not null group by consultant) c)
  );
$function$;

revoke all on function public.notes_kpi_report(date,date,text) from public, anon, authenticated;
grant execute on function public.notes_kpi_report(date,date,text) to service_role;
