-- 0165_screens_financial_year.sql
-- 27/11/2026: Dale asked whether the TV's year-to-date board was the financial year or from January.
-- It was from 1 January. Octagon's financial year runs 1 April to 31 March, so the board now counts
-- Won deals with a close date in the current financial year (1 April to 31 March, by deal owner,
-- through deals_by_consultant() as before). As with the quarter board, a Won deal dated later in
-- the year counts. 'year' becomes the financial-year label, e.g. '2026/27', and 'fy_start' is added.
-- The rank snapshot is retaken, because last Monday's YTD ranks were on the calendar-year basis.
create or replace function public.screens_boards()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp
as $function$
declare
  td date := (now() at time zone 'Europe/London')::date;
  fy int := case when extract(month from td) >= 4 then extract(year from td)::int else extract(year from td)::int - 1 end;
  q jsonb := public.billing_report();
  y jsonb := public.deals_by_consultant(make_date(fy, 4, 1), make_date(fy + 1, 4, 1), null);
begin
  return jsonb_build_object(
    'quarter_start', q->'quarter_start',
    'year', fy || '/' || lpad(((fy + 1) % 100)::text, 2, '0'),
    'fy_start', make_date(fy, 4, 1),
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

revoke execute on function public.screens_boards() from public, anon, authenticated;
grant execute on function public.screens_boards() to service_role;

select public.screens_snapshot();
