-- 0019_admin_telemetry.sql
-- Admin observability + the Slack "admin digest" bot.
--
--   mcp_call_log        one row per MCP tool call (who/what/when) — no PII args
--   admin_digest()      rolls up connector usage + business pulse + sync health
--   post_admin_digest() formats a Slack message and POSTs it to app_settings
--                       .admin_webhook_url (service_role-only, like the alert hook)
--   pg_cron daily 08:00 runs it
--
-- "Who's using it the most / what they run" comes from OUR OWN telemetry (reliable).
-- Claude-plan seat/spend usage is external (Anthropic) and depends on plan tier —
-- not included here; wire it in once the plan/data source is confirmed.

create table if not exists public.mcp_call_log (
  id                       uuid primary key default gen_random_uuid(),
  consultant_recruitcrm_id bigint,
  tool                     text not null,
  ok                       boolean not null default true,
  created_at               timestamptz not null default now()
);
alter table public.mcp_call_log enable row level security;
drop policy if exists mcp_call_log_read_auth on public.mcp_call_log;
create policy mcp_call_log_read_auth on public.mcp_call_log for select to authenticated using (true);
create index if not exists mcp_call_log_created_idx on public.mcp_call_log (created_at);

insert into public.app_settings(key, value) values ('admin_webhook_url', null)
  on conflict (key) do nothing;

create or replace function public.admin_digest()
returns jsonb language sql stable security definer set search_path to 'public' as $function$
  with u7 as (select * from mcp_call_log where created_at > now() - interval '7 days'),
  top_users as (
    select coalesce(co.name, 'user '||l.consultant_recruitcrm_id::text) name, count(*) n
    from u7 l left join consultants co on co.recruitcrm_id = l.consultant_recruitcrm_id
    group by 1 order by n desc limit 5),
  top_tools as (select tool, count(*) n from u7 group by tool order by n desc limit 6)
  select jsonb_build_object(
    'generated_at', now(),
    'health', (select public.sync_health()->>'overall'),
    'usage_7d', jsonb_build_object(
      'calls',  (select count(*) from u7),
      'users',  (select count(distinct consultant_recruitcrm_id) from u7),
      'errors', (select count(*) from u7 where not ok),
      'top_users', (select coalesce(jsonb_agg(jsonb_build_object('name',name,'calls',n) order by n desc),'[]'::jsonb) from top_users),
      'top_tools', (select coalesce(jsonb_agg(jsonb_build_object('tool',tool,'calls',n) order by n desc),'[]'::jsonb) from top_tools)),
    'writes_7d', (select count(*) from audit_log where created_at > now() - interval '7 days'),
    'tokens', jsonb_build_object(
      'active',    (select count(*) from mcp_tokens where active),
      'can_write', (select count(*) from mcp_tokens where active and can_write)),
    'business_7d', jsonb_build_object(
      'cv_sent', (select count(*) from candidate_stage_events where stage_metric='cv_sent' and event_date > current_date - 7),
      'placed',  (select count(*) from candidate_stage_events where stage_metric='placed'  and event_date > current_date - 7),
      'cold_open_roles', (select count(*) from jobs j where j.deleted_at is null and j.status='Open'
          and not exists (select 1 from candidate_stage_events e where e.job_slug=j.slug and e.event_date > current_date - 14)))
  );
$function$;

create or replace function public.post_admin_digest()
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare d jsonb; hook text; msg text; tu text; tt text;
begin
  d := public.admin_digest();
  select value into hook from app_settings where key = 'admin_webhook_url';
  select string_agg((x->>'name')||' '||(x->>'calls'), ', ') into tu from jsonb_array_elements(d->'usage_7d'->'top_users') x;
  select string_agg((x->>'tool')||' '||(x->>'calls'), ', ') into tt from jsonb_array_elements(d->'usage_7d'->'top_tools') x;
  msg := '*Octagon admin digest* (' || to_char(now(),'Dy DD Mon') || ')' || E'\n'
      || '• Sync health: ' || coalesce(d->>'health','?') || E'\n'
      || '• Connector 7d: ' || (d->'usage_7d'->>'calls') || ' calls · ' || (d->'usage_7d'->>'users') || ' users · ' || (d->'usage_7d'->>'errors') || ' errors' || E'\n'
      || '• Top users: ' || coalesce(tu,'—') || E'\n'
      || '• Top tools: ' || coalesce(tt,'—') || E'\n'
      || '• Write actions via Claude 7d: ' || (d->>'writes_7d') || E'\n'
      || '• Access tokens: ' || (d->'tokens'->>'active') || ' active (' || (d->'tokens'->>'can_write') || ' can write)' || E'\n'
      || '• Business 7d: ' || (d->'business_7d'->>'cv_sent') || ' CVs · ' || (d->'business_7d'->>'placed') || ' placed · ' || (d->'business_7d'->>'cold_open_roles') || ' cold open roles';
  if hook is not null and length(hook) > 0 then
    perform net.http_post(url := hook, headers := '{"Content-Type":"application/json"}'::jsonb, body := jsonb_build_object('text', msg));
  end if;
  return jsonb_build_object('posted', hook is not null and length(hook) > 0, 'message', msg);
end $function$;

revoke all on function public.admin_digest()      from public, anon, authenticated;
revoke all on function public.post_admin_digest() from public, anon, authenticated;
grant execute on function public.admin_digest()      to service_role;
grant execute on function public.post_admin_digest() to service_role;

select cron.unschedule('admin-digest')
  where exists (select 1 from cron.job where jobname = 'admin-digest');
select cron.schedule('admin-digest', '0 8 * * *', $$select public.post_admin_digest();$$);
