-- 0022_bd_funnel.sql
-- Client / business-development funnel, sourced from the company "Company Status"
-- custom field in RecruitCRM (discovered 2026-08-04: 3072/4584 companies classified;
-- the contact pipeline holds only 15 records and is ignored).
--
-- clients.company_status is populated by recruitcrm-sync's mapClient (reads the
-- company's custom_fields "Company Status"). Known values: Prospect, Client, Passive,
-- Engaged, Blocklisted, Do not contact.
--
-- NOT covered (not present in RecruitCRM data): a "Lead" status, "Pitched candidates",
-- and "Job order form complete" — these need a status value / custom field / process
-- in RecruitCRM before they can be reported.

alter table public.clients add column if not exists company_status text;
create index if not exists clients_company_status_idx on public.clients (company_status);

create or replace function public.bd_report()
returns jsonb language sql stable security definer set search_path to 'public' as $function$
  select jsonb_build_object(
    'generated_at', now(),
    'definition', 'Client/BD funnel from the company "Company Status" field (synced from RecruitCRM company custom fields). Companies without a status are excluded. RecruitCRM has no "Lead" status; "Pitched candidates" and "Job order form complete" are not tracked in this field.',
    'total_companies', (select count(*) from clients where deleted_at is null),
    'classified',      (select count(*) from clients where deleted_at is null and company_status is not null),
    'by_status', (select coalesce(jsonb_agg(jsonb_build_object('status', company_status, 'companies', n) order by n desc), '[]'::jsonb)
        from (select company_status, count(*) n from clients
              where deleted_at is null and company_status is not null
              group by company_status) s)
  );
$function$;

revoke all on function public.bd_report() from public, anon, authenticated;
grant execute on function public.bd_report() to service_role;
