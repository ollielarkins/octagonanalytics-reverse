-- 0145_contacts_mirror.sql
-- Contacts (the people at client companies) mirrored from RecruitCRM, so activity logged against a
-- contact can be tied to its company. Until now contacts were read live only, and most BD and client
-- calls are logged against the contact (4,188 calls to 1,279 contacts, against 124 calls logged on a
-- company), so company-level views could not see them: /lapsed's last touch, BD activity per client.
--
-- Only what linking and reporting need: name, company, job title, owner, dates. No email or phone:
-- contact details stay in RecruitCRM, where client_status and send_email read them live.
-- Synced by recruitcrm-sync like clients: incremental with the 15-minute run (entity=all), a
-- backfill on demand, and a daily reconcile that soft-deletes contacts removed in RecruitCRM.

create table if not exists public.contacts (
  recruitcrm_id bigint primary key,
  slug text unique,
  first_name text,
  last_name text,
  name text,
  company_slug text,
  designation text,
  owner_recruitcrm_id bigint,
  created_date timestamptz,
  updated_date timestamptz,
  deleted_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists contacts_company_slug_idx on public.contacts (company_slug) where deleted_at is null;
alter table public.contacts enable row level security;
revoke all on table public.contacts from anon, authenticated;

-- reconcile_entity: contacts join the tables a complete live walk may soft-delete from.
create or replace function public.reconcile_entity(p_table text, p_live_ids bigint[])
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_deleted int; v_restored int;
begin
  if p_table not in ('consultants','clients','jobs','contacts') then
    raise exception 'reconcile_entity: table % not allowed', p_table;
  end if;
  if coalesce(array_length(p_live_ids, 1), 0) = 0 then
    return jsonb_build_object('error', 'empty_live_ids — refused');
  end if;

  execute format(
    'update public.%I set deleted_at = now() where deleted_at is null and not (recruitcrm_id = any($1))',
    p_table
  ) using p_live_ids;
  get diagnostics v_deleted = row_count;

  execute format(
    'update public.%I set deleted_at = null where deleted_at is not null and recruitcrm_id = any($1)',
    p_table
  ) using p_live_ids;
  get diagnostics v_restored = row_count;

  return jsonb_build_object('soft_deleted', v_deleted, 'restored', v_restored);
end $function$;

-- sync_health: the contacts feed (strict, like clients) and its daily reconcile.
create or replace function public.sync_health()
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  with cfg(entity, category, warn_min, crit_min, strict_status) as (
    values
      ('candidates','live',20,45,true),
      ('clients','live',20,45,true),
      ('contacts','live',20,45,true),
      ('consultants','live',20,45,true),
      ('jobs','live',20,45,true),
      ('calls','live',20,45,true),
      ('deals','live',20,45,true),
      ('history_recent','live',25,60,false),
      ('notes','live',25,60,false),
      ('meetings','live',25,60,false),
      ('offlimit','reconcile',120,240,false),
      ('reconcile:clients','reconcile',120,240,false),
      ('reconcile:contacts','reconcile',1500,2880,false),
      ('reconcile:jobs','reconcile',120,240,false),
      ('reconcile:deals','reconcile',120,240,false),
      ('backfill:candidates','reconcile',840,1080,false)
  ),
  good(status) as (values ('ok'),('caught_up'),('complete'),('resume_next_page')),
  ev as (
    select c.entity, c.category, c.warn_min, c.crit_min, c.strict_status,
           s.last_run_at, s.last_status, coalesce(s.error_count, 0) as error_count, public.sync_status_degraded(c.entity, s.last_status) as degraded,
           round(extract(epoch from (now()-s.last_run_at))/60)::int as mins
    from cfg c left join sync_state s on s.entity = c.entity
  ),
  cls as (
    select entity, category, last_run_at, last_status, mins, error_count,
      case
        -- 0124: two or more failed runs in a row, on any feed.
        when error_count >= 2 then 'critical'
        when last_run_at is null then 'critical'
        -- An error only goes critical once the next scheduled run has also failed to succeed.
        when strict_status and last_status is not null
             and last_status not in (select status from good)
             and mins >= warn_min then 'critical'
        when mins >= crit_min then 'critical'
        -- A single failed run that has not yet had a chance to retry: warn, no Slack alert.
        when strict_status and last_status is not null
             and last_status not in (select status from good) then 'warn'
        -- 0134: a partial failure on a non-strict feed (skipped reconcile, 429 stop, failed page).
        when degraded then 'warn'
        when mins >= warn_min then 'warn'
        else 'ok'
      end as status,
      case
        when error_count >= 2 then 'failing: '||error_count||' runs in a row - '||last_status
        when last_run_at is null then 'no sync run on record'
        when strict_status and last_status is not null
             and last_status not in (select status from good)
             and mins >= warn_min then 'error status: '||last_status
        when mins >= crit_min then 'stale: '||mins||' min since last run'
        when strict_status and last_status is not null
             and last_status not in (select status from good) then 'error status (retrying): '||last_status
        when degraded then 'degraded: '||left(last_status, 120)
        when mins >= warn_min then 'slowing: '||mins||' min since last run'
        else 'fresh'
      end as reason
    from ev
  )
  select jsonb_build_object(
    'generated_at', now(),
    'overall', (select case
                  when bool_or(status='critical') then 'critical'
                  when bool_or(status='warn') then 'warn'
                  else 'ok' end from cls),
    'entities', (select jsonb_agg(jsonb_build_object(
        'entity', entity, 'category', category, 'last_run_at', last_run_at,
        'minutes_stale', mins, 'last_status', last_status, 'error_count', error_count,
        'status', status, 'reason', reason)
        order by (status='critical') desc, (status='warn') desc, entity) from cls)
  );
$function$;

-- Daily contacts reconcile at 03:20, registered so platform_health checks it is scheduled.
select cron.schedule('recruitcrm-reconcile-contacts', '20 3 * * *', $$select net.http_post(
        url:='https://kzcmssldvtjnbwwunuwm.supabase.co/functions/v1/recruitcrm-sync?mode=reconcile&entity=contacts',
        headers:=public.cron_headers(),
        body:='{}'::jsonb,
        timeout_milliseconds:=20000);$$);
insert into cron_manifest (jobname, schedule, note, required) values
  ('recruitcrm-reconcile-contacts', '20 3 * * *', 'contact deletion detection (0145)', true)
on conflict (jobname) do update set schedule = excluded.schedule, note = excluded.note, required = excluded.required;
