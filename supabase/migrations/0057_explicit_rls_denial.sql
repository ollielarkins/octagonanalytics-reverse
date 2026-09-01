-- 0057_explicit_rls_denial.sql
-- Six tables had RLS enabled with no policy at all (advisor 0008_rls_enabled_no_policy).
--
-- This was never a hole. RLS on with zero policies denies everything to anon and authenticated, and
-- service_role bypasses RLS entirely — which is how all six are actually reached, since every edge
-- function connects with the service key and nothing in web/ or scripts/ touches PostgREST with the
-- anon key. So behaviour here is unchanged.
--
-- What was missing was intent. "No policy" and "policy we forgot to write" look identical in the
-- schema, and two of these tables hold live auth material (mcp_tokens, oauth_codes) while two more
-- hold candidate PII (notes) and internal config (app_settings). An explicit deny states the
-- decision, survives review, and clears the lint so a genuine future gap is not lost in the noise.

do $do$
declare t text;
begin
  foreach t in array array['app_settings','feedback','mcp_tokens','notes','oauth_codes','webhook_events']
  loop
    execute format('drop policy if exists %I on public.%I', 'service_role_only', t);
    execute format(
      'create policy %I on public.%I as restrictive for all to anon, authenticated using (false) with check (false)',
      'service_role_only', t);
  end loop;
end
$do$;

comment on table public.app_settings   is 'Service-role only. Holds alert/standup webhook URLs. RLS denies anon+authenticated explicitly (0057).';
comment on table public.mcp_tokens     is 'Service-role only. Hashed Octagon bearer tokens. RLS denies anon+authenticated explicitly (0057).';
comment on table public.oauth_codes    is 'Service-role only. Short-lived OAuth 2.1 authorisation codes. RLS denies anon+authenticated explicitly (0057).';
comment on table public.notes          is 'Service-role only. Mirrored RecruitCRM notes — candidate PII. RLS denies anon+authenticated explicitly (0057).';
comment on table public.feedback       is 'Service-role only. In-product feedback, written by the feedback edge function. RLS denies anon+authenticated explicitly (0057).';
comment on table public.webhook_events is 'Service-role only. Raw RecruitCRM webhook deliveries. RLS denies anon+authenticated explicitly (0057).';
