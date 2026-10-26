-- 0111_diary_digest_date_window.sql
-- 0110's feedback-due window was a rolling 96 hours, so the answer depended on the time of day: at
-- 10:47 on Monday 26/10/2026 it dropped Adam's Thursday-morning interviews that the 07:30 brief
-- would have shown. The window is now the last four calendar days in UK time, the same whenever it
-- runs: Monday's brief covers Thursday to Sunday, Tuesday's Friday to Monday.

create or replace function public.diary_digest()
returns jsonb language sql stable security definer set search_path = public, pg_temp
as $function$
  with nwd as (
    select (current_date + case extract(dow from current_date)::int when 5 then 3 when 6 then 2 else 1 end) d
  ),
  iv as (
    select m.*, co.name consultant, c.name candidate, j.title job, cl.company_name client,
           (m.start_at at time zone 'Europe/London') local_start,
           coalesce(m.end_at, m.start_at + interval '1 hour') ends
    from meetings m
    join consultants co on co.recruitcrm_id = m.owner_recruitcrm_id and co.deleted_at is null
    left join candidates c on c.slug = m.candidate_slug
    left join jobs j on j.slug = m.job_slug
    left join clients cl on cl.company_slug = j.company_slug
    where m.deleted_at is null and m.meeting_type ~* '^candidate' and m.meeting_type ~* 'interview'
  ),
  prep as (
    select * from iv where local_start::date = (select d from nwd)
  ),
  fb as (
    select * from iv
    where candidate_slug is not null
      and local_start::date >= current_date - 4
      and ends + interval '2 hours' < now()
      and not exists (select 1 from call_activity ca where ca.related_to = iv.candidate_slug
                        and ca.custom_call_type ilike '%feedback%' and ca.call_started_on >= iv.start_at)
      and not exists (select 1 from notes n where n.related_to = iv.candidate_slug and n.created_on >= iv.start_at)
      and not exists (select 1 from candidate_stage_events e where e.candidate_slug = iv.candidate_slug
                        and (iv.job_slug is null or e.job_slug = iv.job_slug)
                        and e.event_timestamp > (iv.start_at at time zone 'UTC'))
  ),
  people as (select consultant from prep union select consultant from fb)
  select jsonb_build_object(
    'prep_day', (select d from nwd),
    'synced', (select last_run_at from sync_state where entity = 'meetings'),
    'prep_total', (select count(*) from prep),
    'feedback_total', (select count(*) from fb),
    'by_consultant', coalesce((select jsonb_agg(jsonb_build_object(
        'consultant', p.consultant,
        'prep', (select coalesce(jsonb_agg(jsonb_build_object(
                    'time', to_char(x.local_start, 'HH24:MI'), 'candidate', coalesce(x.candidate, x.title),
                    'job', x.job, 'client', x.client, 'type', x.meeting_type) order by x.local_start), '[]'::jsonb)
                 from prep x where x.consultant = p.consultant),
        'feedback_due', (select coalesce(jsonb_agg(jsonb_build_object(
                    'held', to_char(x.local_start, 'Dy DD/MM HH24:MI'), 'candidate', coalesce(x.candidate, x.title),
                    'job', x.job, 'client', x.client) order by x.local_start), '[]'::jsonb)
                 from fb x where x.consultant = p.consultant))
      order by p.consultant) from people p), '[]'::jsonb)
  );
$function$;
