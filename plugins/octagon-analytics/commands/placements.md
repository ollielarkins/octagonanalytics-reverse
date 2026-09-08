---
description: Placements with the fee attached — what was placed and what it is worth.
---

Call `placements_with_fees` from the **octagon-analytics** connector. Defaults to this month;
pass `from`, `to` or `consultant` if the user narrows it. State the window as DD/MM/YYYY.

Present:
- **Headline**: placements, total value in £ with thousands separators.
- **By consultant**: placements and value, highest value first.
- **The placements**: job title, consultant, date placed (DD/MM/YYYY), deal value, fee %,
  annual salary. Money as £ with thousands separators; pence only if exact.

Three things you MUST state:

1. **This is not confirmed billing.** It values what was *placed* in the window by joining each
   placement to its job's Won deal. `placements_report` answers a different question — Won deals
   whose *close date* lands in the window — and returns a much lower figure, because deals are
   routinely marked Won with a forward close date. For August 2026 the two give £92,045 and
   £5,250 on the same 11 placements. Neither is wrong; the firm has not yet settled which one
   billing means. Never present either as confirmed revenue.

2. **Invoices are not mirrored.** There is no invoice data in this platform at all, so invoice or
   payment status cannot be confirmed here — check RecruitCRM directly.

3. **A placement showing no value** means the deal has not been moved to Won, not that the
   placement is missing. That is a chase on the deal record.

Close with any placement missing a Won deal, as the admin to clear.
