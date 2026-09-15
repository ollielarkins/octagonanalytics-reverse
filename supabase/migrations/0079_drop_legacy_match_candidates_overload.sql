-- 0079_drop_legacy_match_candidates_overload.sql
-- match_candidates had two overloads. The 3-arg one predates off-limit filtering (0026-era); the
-- 4-arg one added p_include_off_limit and is what octagon-mcp calls, always with all four named
-- params. The 4-arg version defaults that argument, so a 3-arg call matches BOTH signatures and
-- Postgres refuses it: "function match_candidates(text[], unknown, integer) is not unique".
--
-- The connector is unaffected (named params bind it to the 4-arg version) and no SQL function calls
-- it, so the old signature is unreachable code that can only break ad-hoc queries. Worse, if anything
-- ever did resolve to it, it would return OFF-LIMIT candidates - 88 people who must never be pitched.
drop function if exists public.match_candidates(text[], text, integer);
