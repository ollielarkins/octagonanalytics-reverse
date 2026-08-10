-- 0050_deals_slug.sql
-- The deal write endpoints are keyed by slug (POST /v1/deals/{deal}), but the mirror only stored
-- recruitcrm_id. The slug was there all along, buried in resource_url
-- (https://app.recruitcrm.io/deal/<slug>), so this backfills from that rather than re-fetching
-- 1,600 deals from the API.
alter table public.deals add column if not exists slug text;
update public.deals
   set slug = split_part(resource_url, '/', 5)
 where slug is null and resource_url like 'https://app.recruitcrm.io/deal/%';
create index if not exists deals_slug_idx on public.deals (slug);
