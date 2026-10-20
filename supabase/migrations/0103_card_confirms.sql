-- One-time confirmations for the preview cards (octagon-mcp 3.65.0).
--
-- Each two-step write tool's preview hands out a nonce in _card.confirm_args. A confirm that
-- carries one is applied only if its nonce is new here, so a card re-rendered when a chat is
-- reopened, or a button press followed by a "yes" in the chat, cannot apply the same change twice.
-- A failed insert refuses the write, so if this table were missing, card confirms would refuse
-- (nothing changes) rather than risk a duplicate.
create table if not exists public.mcp_card_confirms (
  nonce                    text primary key,
  tool                     text not null,
  consultant_recruitcrm_id text,
  used_at                  timestamptz not null default now()
);
create index if not exists mcp_card_confirms_used_at_idx on public.mcp_card_confirms (used_at);
alter table public.mcp_card_confirms enable row level security;   -- service role only
