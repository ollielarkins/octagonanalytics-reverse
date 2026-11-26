-- 0163_office_screens_feed.sql
-- 26/11/2026: the office TV screens (oct-screens.netlify.app) were fed by a Google Sheet that Dale
-- updated by hand, and had fallen months behind (YTD showed Keelan at £37,932 against £151,570 in
-- RecruitCRM). The number slides now read this feed, served by the screens-feed function.
--
-- Not a return of the public dashboard retired on 03/11/2026: the feed needs a screen key (one per
-- TV or office, stored only as a SHA-256 hash, revocable), and it carries only what the TVs already
-- show on the office wall: billing by consultant, targets, and open roles by company. No candidate,
-- contact or deal-level data.
--
-- One definition per metric: the feed reads billing_report() and deals_by_consultant(), so the TVs
-- match the connector's billing scorecard and deals widget.
--   ytd             Won deal value with a close date in this calendar year, by deal owner. Like the
--                   quarter board, a Won deal dated later this year counts, otherwise Q4 on the TV
--                   would show £0 (every Q4 Won deal on 26/11/2026 is dated after today).
--   quarter         billing_report().won_qtr against quarterly_target.
--   offers_placements  deals at Offered now (offered_value) and won_qtr, by deal owner.
--   leads           the 8 newest Open jobs created in the last 30 days: company and job title.
--   move            rank now against the rank in the Monday snapshot (screens_rank_snapshot), so
--                   "up" means up since the start of the week. Flat when there is no snapshot.
-- Leavers stay in, tagged left; the page decides whether to show them.

create table if not exists public.screen_keys (
  id           uuid primary key default gen_random_uuid(),
  label        text not null,
  key_hash     text not null unique,
  created_at   timestamptz not null default now(),
  last_used_at timestamptz,
  revoked_at   timestamptz
);
alter table public.screen_keys enable row level security;
revoke all on public.screen_keys from public, anon, authenticated;

create table if not exists public.screens_rank_snapshot (
  week_start date not null,
  board      text not null check (board in ('ytd', 'quarter')),
  name       text not null,
  rank       int  not null,
  revenue    numeric not null,
  primary key (week_start, board, name)
);
alter table public.screens_rank_snapshot enable row level security;
revoke all on public.screens_rank_snapshot from public, anon, authenticated;

-- Current boards, ranked. Shared by the feed and the weekly snapshot.
create or replace function public.screens_boards()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp
as $function$
declare
  td date := (now() at time zone 'Europe/London')::date;
  yr int := extract(year from (now() at time zone 'Europe/London'))::int;
  q jsonb := public.billing_report();
  y jsonb := public.deals_by_consultant(make_date(yr, 1, 1), make_date(yr + 1, 1, 1), null);
begin
  return jsonb_build_object(
    'quarter_start', q->'quarter_start',
    'year', yr,
    'ytd', (select coalesce(jsonb_agg(jsonb_build_object('name', r.name, 'left', r.left_firm, 'revenue', r.rev, 'rank', r.rk) order by r.rk), '[]'::jsonb)
              from (select c->>'name' name, (c->>'left_firm')::boolean left_firm, (c->>'won_value')::numeric rev,
                           row_number() over (order by (c->>'won_value')::numeric desc, c->>'name') rk
                      from jsonb_array_elements(y->'consultants') c where (c->>'won_value')::numeric > 0) r),
    'quarter', (select coalesce(jsonb_agg(jsonb_build_object('name', r.name, 'left', r.lft, 'revenue', r.rev, 'target', r.tgt, 'rank', r.rk) order by r.rk), '[]'::jsonb)
              from (select c->>'name' name, (c->>'left')::boolean lft, (c->>'won_qtr')::numeric rev, (c->>'quarterly_target')::numeric tgt,
                           row_number() over (order by (c->>'won_qtr')::numeric desc, c->>'name') rk
                      from jsonb_array_elements(q->'consultants') c
                     where (c->>'won_qtr')::numeric > 0 or (not (c->>'left')::boolean and c->>'quarterly_target' is not null)) r),
    'offers_placements', (select coalesce(jsonb_agg(jsonb_build_object('name', x.name, 'left', x.lft, 'offers', x.offers, 'placements', x.placed)
                                   order by x.offers + x.placed desc, x.name), '[]'::jsonb)
              from (select coalesce(qc->>'name', yc->>'name') name,
                           coalesce((qc->>'left')::boolean, (yc->>'left_firm')::boolean, false) lft,
                           coalesce((yc->>'offered_value')::numeric, 0) offers,
                           coalesce((qc->>'won_qtr')::numeric, 0) placed
                      from jsonb_array_elements(q->'consultants') qc
                      full join jsonb_array_elements(y->'consultants') yc on yc->>'name' = qc->>'name') x
             where x.offers + x.placed > 0)
  );
end;
$function$;

create or replace function public.screens_feed()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp
as $function$
declare
  b jsonb := public.screens_boards();
  snap date := (select max(week_start) from screens_rank_snapshot);
begin
  return jsonb_build_object(
    'generated_at', now(),
    'year', b->'year',
    'quarter_start', b->'quarter_start',
    'moves_since', snap,
    'ytd', (select coalesce(jsonb_agg(e || jsonb_build_object('move',
                case when s.rank is null then 'flat' when (e->>'rank')::int < s.rank then 'up' when (e->>'rank')::int > s.rank then 'down' else 'flat' end)
              order by (e->>'rank')::int), '[]'::jsonb)
            from jsonb_array_elements(b->'ytd') e
            left join screens_rank_snapshot s on s.week_start = snap and s.board = 'ytd' and s.name = e->>'name'),
    'quarter', (select coalesce(jsonb_agg(e || jsonb_build_object('move',
                case when s.rank is null then 'flat' when (e->>'rank')::int < s.rank then 'up' when (e->>'rank')::int > s.rank then 'down' else 'flat' end)
              order by (e->>'rank')::int), '[]'::jsonb)
            from jsonb_array_elements(b->'quarter') e
            left join screens_rank_snapshot s on s.week_start = snap and s.board = 'quarter' and s.name = e->>'name'),
    'offers_placements', b->'offers_placements',
    'leads', (select coalesce(jsonb_agg(jsonb_build_object('client', l.company_name, 'role', l.title) order by l.created_date desc), '[]'::jsonb)
              from (select c.company_name, j.title, j.created_date
                      from jobs j join clients c on c.id = j.client_id
                     where j.deleted_at is null and j.status = 'Open'
                       and j.created_date >= (now() at time zone 'Europe/London') - interval '30 days'
                       and coalesce(c.company_name, '') <> '' and coalesce(j.title, '') <> ''
                     order by j.created_date desc limit 8) l)
  );
end;
$function$;

-- Monday snapshot of both boards: the baseline the arrows compare against. Keeps 12 weeks.
create or replace function public.screens_snapshot()
returns int language plpgsql security definer set search_path = public, pg_temp
as $function$
declare
  b jsonb := public.screens_boards();
  wk date := date_trunc('week', (now() at time zone 'Europe/London'))::date;
  n int;
begin
  delete from screens_rank_snapshot where week_start = wk or week_start < wk - 84;
  insert into screens_rank_snapshot (week_start, board, name, rank, revenue)
  select wk, brd, e->>'name', (e->>'rank')::int, (e->>'revenue')::numeric
    from (values ('ytd'), ('quarter')) v(brd), jsonb_array_elements(b->brd) e;
  get diagnostics n = row_count;
  return n;
end;
$function$;

revoke execute on function public.screens_boards() from public, anon, authenticated;
revoke execute on function public.screens_feed() from public, anon, authenticated;
revoke execute on function public.screens_snapshot() from public, anon, authenticated;
grant execute on function public.screens_boards() to service_role;
grant execute on function public.screens_feed() to service_role;
grant execute on function public.screens_snapshot() to service_role;

-- 00:30 UTC Monday is 00:30 or 01:30 UK: Monday either way.
select cron.schedule('screens-weekly-snapshot', '30 0 * * 1', $$select public.screens_snapshot()$$);
insert into cron_manifest (jobname, schedule, note, required)
values ('screens-weekly-snapshot', '30 0 * * 1', 'Monday baseline for the office TV up/down arrows (0163)', true)
on conflict (jobname) do update set schedule = excluded.schedule, note = excluded.note, required = true;

-- First baseline now, so the arrows have something to compare against this week.
select public.screens_snapshot();
