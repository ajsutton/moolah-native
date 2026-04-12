# Known Bugs

## macOS: Upcoming transactions in Analysis open edit dialog instead of detail sidebar

**Location:** `Features/Analysis/Views/UpcomingTransactionsCard.swift` (likely)

On macOS, clicking an upcoming transaction in the Analysis view shows an edit dialog/sheet. It should instead show the transaction detail panel in a right-hand sidebar, matching the behavior when viewing transactions in an account view.

**Impact:** Inconsistent navigation pattern on macOS. Users expect the same detail sidebar used elsewhere in the app.

**Fix:** Use the same navigation/selection pattern as the account transaction list — push to detail in a sidebar rather than presenting a modal edit sheet.

## Transaction download shows indeterminate spinner instead of progress bar

**Location:** `Features/Transactions/TransactionStore.swift`, `Features/Transactions/Views/TransactionListView.swift`

The transaction list shows a simple spinner (`ProgressView()`) while loading transactions. The server already returns `totalNumberOfTransactions` in every response, so we could show a deterministic progress bar (e.g., "Loading 50 of 230 transactions").

**Impact:** Users with many transactions have no sense of how long the download will take.

**Fix:** Track `loadedCount` and `totalCount` in `TransactionStore` from the server's `totalNumberOfTransactions` field, and replace the spinner with a `ProgressView(value:total:)`.

## UI freeze while downloading investment values

**Location:** Investment value download or validate/save step (exact location TBD)

The UI freezes (becomes unresponsive) during the investment values download process. The freeze may occur during the network fetch itself or during the final validation/save step when persisting the downloaded values.

**Impact:** App appears hung; user cannot interact until the operation completes.

**Fix:** Investigate whether the blocking work is happening on the main actor. Likely needs to move heavy computation or batch saves off the main thread.
