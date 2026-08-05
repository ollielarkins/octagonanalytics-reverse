-- 0033_oauth_codes.sql
-- Short-lived authorization codes for the octagon-mcp OAuth 2.1 bridge (so claude.ai's connector
-- can authenticate). A code is created when a recruiter submits their Octagon token on the /authorize
-- page, and exchanged (with PKCE) at /token for an access token. Codes are single-use + expire in 5m.
-- Service-role only (the edge function uses the service key).

create table if not exists public.oauth_codes (
  code                     text primary key,
  consultant_recruitcrm_id bigint not null,
  can_write                boolean not null default false,
  code_challenge           text not null,      -- PKCE S256 challenge
  redirect_uri             text not null,
  expires_at               timestamptz not null,
  created_at               timestamptz not null default now()
);
alter table public.oauth_codes enable row level security;
revoke all on public.oauth_codes from anon, authenticated;
