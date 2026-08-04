-- 0017_mcp_auth.sql
-- Per-user authentication for the MCP connector (product security, Tier 1).
--
-- Replaces the single shared OCTAGON_WRITE_KEY with per-user bearer tokens:
--   * EVERY tool call (read included) must present a valid token -> closes the
--     "reads are wide open to anyone with the URL" hole.
--   * The token maps to a consultant, so the acting identity is derived
--     server-side and can NEVER be spoofed via a tool argument (this is what
--     protects the audit trail's integrity).
--   * can_write is per token, so write access is granted/revoked per person.
--
-- Tokens are stored ONLY as SHA-256 hashes. The plaintext is shown once, at mint
-- time, to whoever runs mint_mcp_token() in the SQL editor — it never lives in the
-- database and is never logged.

create extension if not exists pgcrypto with schema extensions;

create table if not exists public.mcp_tokens (
  id                       uuid primary key default gen_random_uuid(),
  token_hash               text not null unique,   -- sha256(plaintext), hex
  consultant_recruitcrm_id bigint not null,        -- the acting consultant (updated_by on writes)
  label                    text,                    -- human label, e.g. "Keelan – laptop"
  can_write                boolean not null default false,
  active                   boolean not null default true,
  created_at               timestamptz not null default now(),
  last_used_at             timestamptz
);
-- RLS on, no policies => only service_role (the edge function) can read. Tokens are secrets.
alter table public.mcp_tokens enable row level security;

-- Admin mint helper. Run in the Supabase SQL editor:
--   select public.mint_mcp_token(<recruitcrm_user_id>, 'label', <can_write bool>);
-- It returns the plaintext token ONCE. Store the hash, hand the token to the user.
create or replace function public.mint_mcp_token(
  p_recruitcrm_id bigint, p_label text, p_can_write boolean default false)
returns text
language plpgsql
security definer
set search_path to 'public'
as $function$
declare tok text;
begin
  tok := encode(extensions.gen_random_bytes(24), 'hex');   -- 48-char secret
  insert into mcp_tokens(token_hash, consultant_recruitcrm_id, label, can_write)
    values (encode(extensions.digest(tok, 'sha256'), 'hex'), p_recruitcrm_id, p_label, p_can_write);
  return tok;
end;
$function$;

revoke all on function public.mint_mcp_token(bigint, text, boolean) from public, anon, authenticated;
grant execute on function public.mint_mcp_token(bigint, text, boolean) to service_role;
