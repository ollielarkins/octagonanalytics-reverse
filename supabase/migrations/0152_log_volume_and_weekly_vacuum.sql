-- 0152_log_volume_and_weekly_vacuum.sql
-- 05/11/2026, Free plan limits: Log Ingestion 1.53 of 1 GB, database 449 of 500 MB.
--
-- 1. history-recent: every minute -> every 5 minutes. 0060 set every minute to drain a 17,000
--    candidate backlog in August. The queue is now empty (sync_state: queue=0) and averages about
--    2 candidates a minute, so most runs do nothing but their fixed calls. Edge logs over 24 hours
--    (31,650 requests) were led by this job: 3,415 sync_state upserts and 1,435
--    candidates_due_for_history calls, all fixed cost per run. At 5 minutes those fall about 80%;
--    the per-candidate writes are unchanged, because the same candidates are walked, just in
--    batches. 50 candidates per run is still about 25x the current rate. Health warns after 30
--    minutes, so 5 is well inside it. Funnel events can now lag RecruitCRM by up to 5 minutes.
--    Changed with cron.alter_job, so the job's command (URL, parameters) stays as 0060 set it.
--
-- 2. vacuum-http-response, Sundays 04:30 UK: pg_net deletes its own old rows but never gives the
--    space back. net._http_response held 155 MB for 633 live rows before the manual vacuum full
--    on 05/11/2026. A weekly vacuum full keeps it small. It locks the table for a few seconds,
--    and pg_net requests made in that moment just wait.

select cron.alter_job(job_id := (select jobid from cron.job where jobname = 'history-recent'),
                      schedule := '*/5 * * * *');
update cron_manifest set schedule = '*/5 * * * *',
       note = 'candidate stage events - the funnel feed (0060); every 5 minutes from 0152'
 where jobname = 'history-recent';

select cron.schedule('vacuum-http-response', '30 4 * * 0', $$vacuum full net._http_response$$);
insert into cron_manifest (jobname, schedule, note, required)
values ('vacuum-http-response', '30 4 * * 0', 'weekly vacuum full of net._http_response, which pg_net never shrinks (0152)', true)
on conflict (jobname) do update set schedule = excluded.schedule, note = excluded.note, required = true;
