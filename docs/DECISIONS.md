# Design Decisions — Octagon Analytics

Running log of the decisions behind the schema and semantic layer. Each entry: the decision, why, and status. This exists so the "one canonical definition per metric" promise is written down, not just implied by SQL.

---

## D1 — Canonical event source for the funnel: `candidate_stage_events`

**Decision.** All funnel/activity metrics (cv_sent, interview stages, offers, placements, conversion ratios, stage timing) are computed from **`candidate_stage_events`** — and nothing else. `deal_stage_events` and `daily_activity` are **not** blended into the funnel.

**Why.** The audit found the *same* metric computed from three different tables, which cannot agree. `candidate_stage_events` is the richest and most granular source (candidate_id, job_slug, consultant, stage_metric, event_date), so it's the natural single source of truth.
- `deal_stage_events` is deal-level, not candidate-level, and had RLS off — it's demoted to deal-stage-history only.
- `daily_activity` is a pre-aggregated import of **unconfirmed provenance** (open question in the brief). It is kept as a *separate* "reported activity" fact and surfaced in its own view, clearly labelled as a different source — never summed together with event-derived counts.

**Status:** Proposed — please confirm. (This is the main judgement call in the rebuild.)

---

## D2 — Stage taxonomy: `stage_metric` is canonical; `stage_name` is display-only

**Decision.** Views key off the machine token **`stage_metric`** (`cv_sent`, `interview_request`, `first_interview`, `second_interview`, `offered`, `placed`, `rejected_consultant`, `rejected_client`). `stage_name` ('CV Sent', '1st Interview', …) is human-facing only. A lookup table maps RecruitCRM integer stage IDs → (`stage_metric`, `stage_name`).

**Why.** The legacy views mixed the two (one funnel view keyed off `stage_name`, others off `stage_metric`), so they silently diverged. Picking one canonical key removes that class of bug. RecruitCRM uses integer stage IDs, so a lookup is needed anyway.

**Status:** Proposed.

---

## D3 — Reporting exclusions live in a table, not hardcoded in SQL

**Decision.** The people currently hardcoded as `consultant <> ALL('Laura','Matthew','Aimee')` move into a table `public.reporting_exclusions(consultant_name text, reason text)`. Every consultant-facing view joins/anti-joins to it, so the rule is applied **once, consistently**.

**Why.** The exclusion was applied in some views and not others → two "consultant funnel" views returned different numbers. Hardcoded names in 10+ view bodies are unmaintainable. One table = one rule, editable without DDL.

**Open question:** who are Laura/Matthew/Aimee and why excluded (directors/managers not measured on consultant productivity)? Confirm the list is correct and complete before data lands.

**Status:** Proposed.

---

## D4 — One definition of "placement"

**Decision.** Two candidate definitions exist: (a) a row in the `placements` table, (b) `count(stage_metric='placed')` in the event stream. Until real data lets us reconcile them, the **canonical "placement" for funnel/consultant/team metrics is the event-stream `placed` count** (b), because the whole funnel is built on `candidate_stage_events` (D1). The `placements` table is treated as the **finance/fee source of record** (fee_amount, placement_date, salary) and reconciled against (b) once data lands.

**Why.** Mixing the two silently double-counts or disagrees. Keep the funnel internally consistent (all from one source), and treat `placements` as the authoritative money view, then reconcile.

**Status:** Proposed — revisit once real data exists.

---

## D5 — Revenue vs pipeline are distinct, explicitly defined

**Decision.**
- **Pipeline value** = `sum(deal_value)` over **open** deals (not Won/Lost).
- **Revenue (won)** = `sum(deal_value)` where `deal_stage = 'Won'`, bucketed by **`close_date`** (the month it closed), not `created_date`.
- **Fees** = `sum(fee_amount)` from `placements` (the finance source of record).

**Why.** Legacy views conflated these: `monthly_revenue` filtered Won but bucketed by created_date; `client_revenue`/`funnel_stage` summed all stages as if revenue. Naming each precisely stops "revenue" meaning three things.

**Status:** Proposed — confirm the exact `deal_stage` label(s) that mean Won/Lost once RecruitCRM values are known.

---

## D6 — Views are `security_invoker`; access via table RLS policies

**Decision.** All semantic-layer views are recreated with `WITH (security_invoker = on)`. Base tables get RLS policies granting **`authenticated` read on all rows** (the "all recruiters see all data" model); `anon` gets nothing (candidate PII).

**Why.** The 19 legacy views were `SECURITY DEFINER` (flagged ERROR ×19 by Supabase) and bypassed RLS — they were the *only* reason data was readable, since base tables had RLS on but no policies. Invoker views + real policies make access explicit, auditable, and consistent between dashboards and Claude.

**Status:** Structural policies applied in migration 0001; view recreation in the canonical-views migration.

---

## D7 — Consultant identity unified on `recruitcrm_id`

**Decision.** `consultants.recruitcrm_id` (bigint, unique) is the canonical consultant key. Event tables keep the raw `consultant` (name) and `consultant_id` (RecruitCRM id) **as landed from the source**, but every view resolves consultant identity by joining on `recruitcrm_id`. Free-text name columns become display-only. `daily_activity.consultant` (name-only) is resolved to `recruitcrm_id` during sync.

**Why.** Consultant was referenced three ways (UUID FK, bigint id, free-text name); "…by consultant/team" answers would otherwise disagree. One canonical key fixes it.

**Status:** Proposed. No destructive schema change needed now (recruitcrm_id already unique); enforced in the sync + view layer.
