-- 0166_screens_week_calls.sql
-- 27/11/2026: the TV's This week slide adds BD calls and client calls, as asked. screens_feed()'s
-- week rows gain bd_calls / client_calls (actual and weekly target) and week_totals gains both,
-- straight from kpis_report() so they match weekly_kpis. As there, calls count only tagged Devyce
-- calls, so untagged calls are not on the screen. Someone with only calls this week now appears.
-- The ranking score is unchanged (calls do not move anyone up the table).
create or replace function public.screens_feed()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp
as $function$
declare
  b jsonb := public.screens_boards();
  k jsonb := public.kpis_report();
  snap date := (select max(week_start) from screens_rank_snapshot);
  wk jsonb;
begin
  select coalesce(jsonb_agg(x.row order by x.score desc, x.row->>'name'), '[]'::jsonb) into wk
    from (select jsonb_build_object(
                   'name', c->>'name',
                   'cv_sent', (c->'cv_sent'->>'actual')::int, 'cv_sent_target', (c->'cv_sent'->>'target')::int,
                   'interview_request', (c->'interview_request'->>'actual')::int, 'interview_request_target', (c->'interview_request'->>'target')::int,
                   'first_interview', (c->'first_interview'->>'actual')::int, 'first_interview_target', (c->'first_interview'->>'target')::int,
                   'bd_calls', (c->'bd_calls'->>'actual')::int, 'bd_calls_target', (c->'bd_calls'->>'target')::int,
                   'client_calls', (c->'client_calls'->>'actual')::int, 'client_calls_target', (c->'client_calls'->>'target')::int,
                   'placed', (c->'placed'->>'actual')::int) row,
                 (c->'cv_sent'->>'actual')::int + 2 * (c->'interview_request'->>'actual')::int
                   + 2 * (c->'first_interview'->>'actual')::int + 10 * (c->'placed'->>'actual')::int score
            from jsonb_array_elements(k->'consultants') c
           where (c->'cv_sent'->>'actual')::int + (c->'interview_request'->>'actual')::int
                 + (c->'first_interview'->>'actual')::int + (c->'placed'->>'actual')::int
                 + (c->'bd_calls'->>'actual')::int + (c->'client_calls'->>'actual')::int > 0
              or c->'cv_sent'->>'target' is not null) x;

  return jsonb_build_object(
    'generated_at', now(),
    'year', b->'year',
    'quarter_start', b->'quarter_start',
    'week_start', k->'week_start',
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
    'week', wk,
    'week_totals', (select jsonb_build_object(
                      'cv_sent', coalesce(sum((c->'cv_sent'->>'actual')::int), 0),
                      'interview_request', coalesce(sum((c->'interview_request'->>'actual')::int), 0),
                      'first_interview', coalesce(sum((c->'first_interview'->>'actual')::int), 0),
                      'bd_calls', coalesce(sum((c->'bd_calls'->>'actual')::int), 0),
                      'client_calls', coalesce(sum((c->'client_calls'->>'actual')::int), 0),
                      'placed', coalesce(sum((c->'placed'->>'actual')::int), 0))
                    from jsonb_array_elements(k->'consultants') c),
    'placements', (select coalesce(jsonb_agg(jsonb_build_object('consultant', p.consultant, 'role', p.title, 'client', p.company_name, 'date', p.event_date)
                                   order by p.event_date desc, p.consultant), '[]'::jsonb)
                   from (select l.consultant, j.title, c.company_name, l.event_date
                           from (select distinct on (e.candidate_slug, e.job_slug) e.candidate_slug, e.job_slug, e.stage_metric, e.consultant, e.event_date
                                   from candidate_stage_events e
                                  where e.event_date >= current_date - 60
                                  order by e.candidate_slug, e.job_slug, e.event_timestamp desc) l
                           join jobs j on j.slug = l.job_slug and j.deleted_at is null
                           join clients c on c.id = j.client_id
                          where l.stage_metric = 'placed' and l.event_date >= current_date - 14
                          order by l.event_date desc limit 8) p),
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

revoke execute on function public.screens_feed() from public, anon, authenticated;
grant execute on function public.screens_feed() to service_role;
