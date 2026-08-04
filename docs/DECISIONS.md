# Design Decisions — Octagon Analytics

Running log of the decisions behind the schema and semantic layer. Each entry: the decision, why, and status. This exists so the "one canonical definition per metric" promise is written down, not just implied by SQL.

---

## D1 — Canonical event source for the funnel: `candidate_stage_events`

**Decision.** All funnel/activity metrics (cv_sent, interview stages, offers, placements, conversion ratios, stage timing) are computed from **`candidate_stage_events`** — and nothing else. `deal_stage_events` and `daily_activity` are **not** blended into the funnel.

**Why.** The audit found the *same* metric computed from three different tables, which cannot agree. `candidate_stage_events` is the richest and most granular source (candidate_id, job_slug, consultant, stage_metric, event_date), so it's the natural single source of truth.
- `deal_stage_events` is deal-level, not candidate-level, and had RLS off — it's demoted to deal-stage-history only.
- `daily_activity` is a pre-aggregated import of **unconfirmed provenance** (open question in the brief). It is kept as a *separate* "reported activity" fact and surfaced in its own view, clearly labelled as a different source — never summed together with event-derived counts.

**Status:** **Confirmed as-built.** `candidate_stage_events` is now populated by the live sync's `history` mode (hiring-stage history per candidate, mapped via `stage_lookup`), and is the sole source for every funnel/consultant metric and for `funnel_report` (0014). Pre-2026 history is sparse in RecruitCRM, so reporting defaults to a 2026-onward window — see [D8].

---

## D2 — Stage taxonomy: `stage_metric` is canonical; `stage_name` is display-only

**Decision.** Views key off the machine token **`stage_metric`** (`cv_sent`, `interview_request`, `first_interview`, `second_interview`, `offered`, `placed`, `rejected_consultant`, `rejected_client`). `stage_name` ('CV Sent', '1st Interview', …) is human-facing only. A lookup table maps RecruitCRM integer stage IDs → (`stage_metric`, `stage_name`).

**Why.** The legacy views mixed the two (one funnel view keyed off `stage_name`, others off `stage_metric`), so they silently diverged. Picking one canonical key removes that class of bug. RecruitCRM uses integer stage IDs, so a lookup is needed anyway.

**Status:** **As-built.** `stage_lookup` maps confirmed RecruitCRM stage ids → `stage_metric` (0008); the sync's `history` mode and all views key off `stage_metric`.

---

## D3 — Reporting exclusions live in a table, not hardcoded in SQL

**Decision.** The people currently hardcoded as `consultant <> ALL('Laura','Matthew','Aimee')` move into a table `public.reporting_exclusions(consultant_name text, reason text)`. Every consultant-facing view joins/anti-joins to it, so the rule is applied **once, consistently**.

**Why.** The exclusion was applied in some views and not others → two "consultant funnel" views returned different numbers. Hardcoded names in 10+ view bodies are unmaintainable. One table = one rule, editable without DDL.

**Open question:** who are Laura/Matthew/Aimee and why excluded (directors/managers not measured on consultant productivity)? Confirm the list is correct and complete before data lands.

**Status:** Superseded in practice. With owner attribution ([D9]) and a 2026-onward window ([D8]), the funnel is driven by who *owns* jobs; non-producing directors simply own few/no jobs and fall out naturally, and leavers are handled as `active = false` rather than a hardcoded name list. The `reporting_exclusions` table remains available as an override but is not the primary mechanism.

---

## D4 — One definition of "placement"

**Decision.** Two candidate definitions exist: (a) a row in the `placements` table, (b) `count(stage_metric='placed')` in the event stream. Until real data lets us reconcile them, the **canonical "placement" for funnel/consultant/team metrics is the event-stream `placed` count** (b), because the whole funnel is built on `candidate_stage_events` (D1). The `placements` table is treated as the **finance/fee source of record** (fee_amount, placement_date, salary) and reconciled against (b) once data lands.

**Why.** Mixing the two silently double-counts or disagrees. Keep the funnel internally consistent (all from one source), and treat `placements` as the authoritative money view, then reconcile.

**Status:** **As-built** for the funnel — the canonical "placement" is the event-stream `placed` count, and write-back sets `create_placement=true` when moving a candidate to Placed (so the two stay coupled at source). `placements`-table fee reconciliation remains a follow-up.

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

**Status:** **As-built.** The sync resolves consultant identity on `recruitcrm_id`; views join on it; owner attribution ([D9]) rests on this key.

---

## D8 — RecruitCRM is the single source of truth (SSOT); Supabase is a live mirror

**Decision.** RecruitCRM is the **single source of truth**. Supabase is a live, always-current mirror of the RecruitCRM API output (via the M2 sync), and everything downstream (semantic layer, dashboards, Claude) reads from that mirror. The current data is a stale one-off hand-import and will be **replaced** by the live sync.

**Consequences.**
- The "Ratios 2025-26" spreadsheet is **NOT** the source of truth — it becomes a *validation reference* only (see [[octagon-ratios-spec]]).
- Where the spreadsheet disagrees with RecruitCRM, the platform reports the **RecruitCRM** figure. Closing the gap is a **data-entry/process** fix (get the activity logged in RecruitCRM), not a reason to bend the platform to the sheet.
- A live mirror guarantees `Supabase == RecruitCRM`; it does **not** guarantee `Supabase == spreadsheet`. That's expected and acceptable under SSOT.
- The chosen canonical funnel source (D1) must be whatever RecruitCRM actually feeds once the sync is live; revisit D1 against real synced data (candidate_stage_events had almost no pre-2026 history in the stale import).

**Status:** **Decided by the user 2026-08-03; now realised.** The live sync (M2) is running; the mirror equals RecruitCRM to ~2-min freshness. The leg-A finding confirmed the sheet was a *manual tally the CRM never contained*: ratios agree (~0.21–0.36) but absolute counts diverge (Jan 2025: mirror 107 vs sheet 223) because pre-2026 activity was never logged. The platform reports the CRM figure; the divergence is a data-entry/process gap, exactly as this decision anticipated.

---

## D9 — Per-consultant attribution is by job owner, not `updated_by`

**Decision.** Every per-consultant metric credits the **owning consultant of the job** the
event belongs to (`jobs.consultant_id`), **not** the user who logged the event
(`updated_by`). `funnel_report` (0014) and the dashboard's consultant table both use owner
attribution.

**Why.** RecruitCRM's `updated_by` records whoever *clicked*, which includes admins, coordinators,
and colleagues moving stages on each other's candidates. Attributing by `updated_by` produced
**impossible funnels** — one consultant credited with 62 CVs but 289 first interviews. Job owner
is the stable "whose desk is this" key and matches how the firm thinks about performance.

**Consequence.** `updated_by` is still captured and set on **write-back** (so RecruitCRM's own
activity log attributes the acting consultant), but it is never the reporting attribution key.

**Status:** **Decided & as-built 2026-08-04.**
