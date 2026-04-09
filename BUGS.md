# Known Bugs

1. **Reports view constant refresh on "Last 12 months"** — The reports view refreshes repeatedly when showing "Last 12 months" time range. Likely recalculating every time the current time changes (e.g., `Date()` in a computed property triggers SwiftUI re-evaluation), but the data won't have changed so it doesn't need to auto-update while on this view since the data won't have changed.

2. **Earmark transactions missing description** — Transactions added directly to earmarks (where the account is an earmark) should show description as "Earmark funds for <earmark name>" but currently display with no description.

3. **Report view monetary amount colouring incorrect** — Report view doesn't apply colouring for monetary amounts correctly (green for positive, red for negative).

4. **Report view missing category drill-down** — Report view should provide a way to view all transactions in a category. In the web UI, each category in the report is a link that navigates to the all-transactions view with filters pre-applied for that category and time range.
