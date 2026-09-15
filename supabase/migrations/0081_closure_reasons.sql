-- 0081_closure_reasons.sql
-- "When I close a job or lose a deal there needs to be an option to say why" (Ollie, 15/09/2026).
--
-- RecruitCRM already models this and nobody uses it. Live webhook payloads carry
-- job_status_comment [{status_id, remark, updated_by, updated_on}] and deal_stage_remarks
-- [{reason, deal_id, stage_id, ...}] - a per-change history with a reason slot. Across all 96
-- samples held in webhook_events, every remark and reason is blank or null.
--
-- Whether RecruitCRM's job/deal UPDATE endpoints ACCEPT that remark is unconfirmed: their docs are a
-- JS app that would not yield the endpoint contract, and there is no offline spec. Sending an
-- unverified field on a working write risks a 400 that breaks job closure outright, so the connector
-- does NOT touch the update payload. The reason is written as a note on the record (add_note is
-- proven) and logged here in structured form. Confirming the native field later is purely additive.
--
-- Kept in its own table rather than as columns on jobs/deals for two reasons: the sync upserts those
-- rows and this must not depend on partial-upsert semantics preserving a column the mapping does not
-- know about; and a job can close, reopen and close again, so the history matters, not the last value.

create table if not exists public.closure_reasons (
  id     bigserial primary key,
  kind   text not null check (kind in ('job','deal')),
  label  text not null,
  sort   int  not null default 100,
  active boolean not null default true,
  unique (kind, label)
);
alter table public.closure_reasons enable row level security;
revoke all on table public.closure_reasons from public, anon, authenticated;

insert into public.closure_reasons (kind, label, sort) values
  ('job','Filled by us',10),
  ('job','Filled by client directly',20),
  ('job','Filled by another agency',30),
  ('job','Role withdrawn',40),
  ('job','Budget pulled',50),
  ('job','Role on hold',60),
  ('job','Client unresponsive',70),
  ('job','Terms not agreed',80),
  ('job','Other',999),
  ('deal','Candidate withdrew',10),
  ('deal','Counter-offer accepted',20),
  ('deal','Client chose another candidate',30),
  ('deal','Client chose another agency',40),
  ('deal','Role withdrawn',50),
  ('deal','Budget pulled',60),
  ('deal','Fee not agreed',70),
  ('deal','Client unresponsive',80),
  ('deal','Other',999)
on conflict (kind, label) do nothing;

create table if not exists public.closure_reason_log (
  id                    bigserial primary key,
  kind                  text not null check (kind in ('job','deal')),
  record_slug           text not null,
  record_name           text,
  new_status            text,
  reason                text not null,
  detail                text,
  actor_recruitcrm_id   bigint,
  note_written          boolean not null default false,
  created_at            timestamptz not null default now()
);
create index if not exists closure_reason_log_kind_created_idx on public.closure_reason_log (kind, created_at desc);
create index if not exists closure_reason_log_slug_idx on public.closure_reason_log (record_slug);
alter table public.closure_reason_log enable row level security;
revoke all on table public.closure_reason_log from public, anon, authenticated;

-- Why we lose. Counts by reason over a window, with the platform's usual semantics: from inclusive,
-- to EXCLUSIVE.
create or replace function public.closure_reasons_report(p_from date default null, p_to date default null, p_kind text default null)
returns jsonb
language sql
stable security definer
set search_path to 'public'
as $function$
  with bounds as (
    select coalesce(p_from, date_trunc('year', current_date)::date) as f,
           coalesce(p_to, (current_date + 1)) as t
  ),
  rows_in as (
    select l.kind, l.reason
      from closure_reason_log l, bounds b
     where l.created_at >= b.f and l.created_at < b.t
       and (p_kind is null or l.kind = p_kind)
  )
  select jsonb_build_object(
    'from', (select f from bounds), 'to', (select t from bounds),
    'kind', coalesce(p_kind, 'all'),
    'total', (select count(*) from rows_in),
    'definition', 'Reasons recorded when a job was closed or a deal marked lost, from closure_reason_log. Only what was logged through Claude - reasons set directly in RecruitCRM are not counted. Window end is exclusive.',
    'by_reason', (select coalesce(jsonb_agg(jsonb_build_object('kind', kind, 'reason', reason, 'count', n) order by n desc, reason), '[]'::jsonb)
                    from (select kind, reason, count(*) as n from rows_in group by kind, reason) s)
  );
$function$;

revoke all on function public.closure_reasons_report(date, date, text) from public, anon, authenticated;
grant execute on function public.closure_reasons_report(date, date, text) to service_role;
