-- Hourly assignment sweep (recruitcrm-sync mode=assignment_sweep): checks every open job's assigned
-- candidates against candidate_assignments and queues any candidate we have not recorded for a
-- history walk. Needed because an assignment does not always bump the candidate's updated_on, which
-- is all the history_recent feed watches. Same trigger shape as the existing reconcile jobs; the
-- function URL and project key are copied from recruitcrm-reconcile-jobs rather than restated.
select cron.schedule('recruitcrm-assignment-sweep', '40 * * * *',
  replace((select command from cron.job where jobname = 'recruitcrm-reconcile-jobs'),
          'mode=reconcile&entity=jobs', 'mode=assignment_sweep'));
