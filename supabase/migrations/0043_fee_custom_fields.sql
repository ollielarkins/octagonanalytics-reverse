-- 0043_fee_custom_fields.sql
-- The fee was never missing: deals.deal_value IS the fee (Won deals median £6,432, 713 of 862
-- between £2k and £30k — fee-shaped, not salary-shaped). What we weren't capturing is how it is
-- arrived at. RecruitCRM holds the components as deal custom fields:
--   Annual Salary · Percentage of Annual Salary · Currency · Start date · End date
-- and a per-role forward indicator as a job custom field: Forecast Fee (£).
--
-- Landing these gives average fee %, average salary placed, contract dates, a forecast pipeline,
-- and a way to sanity-check any deal_value against salary x percentage.
--
-- NOTE: this supersedes decision D5, which defines fees as sum(placements.fee_amount). There is no
-- fee_amount — the placement record carries no money at all (probed 10/08/2026).
--
-- Existing rows stay null until re-upserted by a deals/jobs backfill.
alter table public.deals add column if not exists annual_salary  numeric;
alter table public.deals add column if not exists fee_percentage numeric;
alter table public.deals add column if not exists fee_currency   text;
alter table public.deals add column if not exists start_date     date;
alter table public.deals add column if not exists end_date       date;

alter table public.jobs  add column if not exists forecast_fee   numeric;
