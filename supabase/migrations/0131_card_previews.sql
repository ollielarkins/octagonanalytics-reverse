-- 0131_card_previews.sql
-- Every preview card's nonce, recorded when the preview is issued (octagon-mcp 3.85.0).
--
-- Until now the nonce was only checked for re-use at confirm (mcp_card_confirms, 0103): a confirm
-- with no nonce, or one made up, was applied with no preview behind it, and a real nonce could be
-- confirmed with different arguments than the card showed. Found in the platform audit, 29/10/2026.
-- Now a confirm is applied only if its nonce is here, for the same tool and person, with the exact
-- arguments the preview returned in _card.confirm_args (or draft_args), and not expired.
-- allowed holds the canonical JSON of each permitted argument set (confirm and card_nonce left out).
create table if not exists public.mcp_card_previews (
  nonce                    text primary key,
  tool                     text not null,
  consultant_recruitcrm_id text,
  allowed                  text[] not null,
  created_at               timestamptz not null default now(),
  expires_at               timestamptz not null
);
create index if not exists mcp_card_previews_created_at_idx on public.mcp_card_previews (created_at);
alter table public.mcp_card_previews enable row level security;   -- service role only
drop policy if exists service_role_only on public.mcp_card_previews;
create policy service_role_only on public.mcp_card_previews
  as restrictive for all to anon, authenticated using (false) with check (false);
