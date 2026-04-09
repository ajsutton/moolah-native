# Payee Autocomplete

## Context

The moolah web app provides payee autocomplete when creating or editing transactions. As you type a payee name, it shows a dropdown of matching payees from existing transactions. Selecting a suggestion auto-fills the category, amount, type, and toAccountId from that previous transaction. The native app currently has a plain `TextField("Payee", text: $payee)` with no suggestions or auto-fill.

The native app already has the backend infrastructure partially in place: `TransactionRepository` defines `fetchPayeeSuggestions(prefix:)`, and both `InMemoryTransactionRepository` and `RemoteTransactionRepository` implement it. However, no UI code calls this method, and the `TransactionStore` does not expose it.

## Web Behavior Details

### Data Source
The web app does **not** use a dedicated API endpoint for payee suggestions. Instead, the `AutoCompletePayee.vue` component uses `uniqueTransactions` -- a computed property that iterates over **all transactions already loaded in the Pinia store** and extracts unique payees. Each unique payee maps to its full transaction object (the first occurrence found). There is no server-side search or separate fetch -- it relies entirely on the current page of transactions being in memory.

### Filtering
Vuetify's `v-combobox` handles filtering internally. As the user types, the combobox filters the `uniqueTransactions` list by matching against the `payee` property (item-title). Filtering is case-insensitive substring match. There is no explicit debounce -- the combobox filters on every keystroke.

### Trigger
The autocomplete appears immediately when the user starts typing in the payee field. There is no minimum character threshold.

### UI
A Vuetify combobox dropdown appears below the text field showing matching payees. The user can type freely (it is a combobox, not a strict select). The dropdown shows payee strings only.

### Selection Behavior
When the user selects a suggestion, the `change` method detects it received an object (not a string) and calls `select(transaction)`, which:
1. Sets `this.content` to the payee string
2. Emits an `autofill` event with the full transaction object

The parent `EditTransaction.vue` handles the `autofill` event by patching the current transaction with:
- `payee` -- the selected payee name
- `amount` -- the amount from the matched transaction
- `categoryId` -- the category from the matched transaction
- `type` -- the type (expense/income/transfer) from the matched transaction
- `toAccountId` -- the transfer destination from the matched transaction

This is the key UX feature: selecting a payee pre-fills the most likely category, amount, and type based on past behavior.

### Exclusion
The currently selected/editing transaction is excluded from the suggestion list to avoid suggesting itself.

### Limitations of the Web Implementation
- Only searches transactions already loaded in the current view (one page). If the user is on a filtered view or has paginated away, older payees may not appear.
- Takes the first matching transaction's values for auto-fill, not the most recent or most common.
- No frequency-based ranking -- payees are unordered.

## Potential Native Improvements

### 1. Server-Side Payee Search (already implemented)
**Effort: None (already done)**
The native app's `RemoteTransactionRepository.fetchPayeeSuggestions(prefix:)` queries the server with a payee filter and extracts unique payees from the results. This searches across ALL transactions, not just the loaded page. This is strictly better than the web behavior.

### 2. Auto-Fill with Most Recent Transaction
**Effort: Small**
When a payee is selected, fetch the most recent transaction with that payee to use for auto-fill values. The web app just grabs whichever transaction happens to be first in the loaded list. We can intentionally pick the most recent one, which is more likely to have the correct category/amount.

This requires a minor addition: when fetching suggestions, also return enough transaction data to enable auto-fill. Two approaches:
- **(a)** After the user selects a payee, do a second fetch filtered by that payee (1 result) to get the most recent transaction's category/amount/type. Simple, adds one network request on selection only.
- **(b)** Change `fetchPayeeSuggestions` to return `[PayeeSuggestion]` with category/amount/type attached. More efficient but changes the protocol.

Recommendation: approach (a) for simplicity. The extra request only fires when a suggestion is tapped, not on every keystroke.

### 3. Frequency/Recency-Sorted Suggestions
**Effort: Small-Medium**
Sort suggestions by frequency (most-used payees first) or recency (most recently used first). The web app shows them unsorted. This would require server-side support (a `GROUP BY payee ORDER BY COUNT(*) DESC` query) or client-side processing. Deferring this to a future enhancement since the current implementation returns sorted alphabetically, which is acceptable.

**Decision: Defer. Flag for future consideration.**

### 4. Recent Payees as Quick-Pick Chips
**Effort: Medium**
Show 3-5 recently used payees as tappable chips above the payee field for instant selection without typing. This would be excellent on iOS for one-tap entry of recurring transactions (e.g., "Woolworths", "Coles", "Rent").

**Decision: Defer to a follow-up. The autocomplete dropdown is the priority. Chips could be added later as an enhancement to TransactionDetailView.**

### 5. SwiftUI `.searchSuggestions` API
**Effort: Uncertain**
SwiftUI has `.searchSuggestions` for searchable views, but this applies to `Searchable` contexts, not plain `TextField` in a form. For a form-embedded text field, we need a custom overlay/popover approach. SwiftUI does not have a native combobox widget.

**Decision: Use a custom suggestion overlay. See implementation details below.**

## Implementation Plan

### Step 1: Add `PayeeSuggestion` Model and Store Method

Add a method to `TransactionStore` that calls the existing repository method with debouncing logic, and stores the results.

- **`Features/Transactions/TransactionStore.swift`**: Add:
  - `payeeSuggestions: [String]` published property
  - `fetchPayeeSuggestions(prefix:)` method that calls `repository.fetchPayeeSuggestions(prefix:)` with a debounce (skip if prefix is empty or < 1 character)
  - `clearPayeeSuggestions()` method
  - `fetchTransactionForAutofill(payee:)` method that fetches a single transaction matching the payee (for auto-fill). Uses `repository.fetch(filter: TransactionFilter(payee: payee), page: 0, pageSize: 1)` and returns the first result.

- **Tests**: `MoolahTests/Features/TransactionStoreTests.swift`:
  - Test that `fetchPayeeSuggestions` returns matching payees
  - Test that empty prefix returns empty results
  - Test that `fetchTransactionForAutofill` returns the most recent matching transaction

### Step 2: Create `PayeeSuggestionOverlay` View Component

A reusable component that shows a dropdown of payee suggestions below a text field.

- **`Features/Transactions/Views/PayeeSuggestionOverlay.swift`** (new):
  - Takes a binding to the payee text, a list of suggestions, and an `onSelect` callback
  - Renders as a `List` or `ScrollView` in a popover/overlay anchored below the text field
  - Shows when suggestions are non-empty and the text field is focused
  - Each row shows the payee name; tapping calls `onSelect(payee)`
  - Keyboard support: arrow keys to navigate suggestions on macOS
  - Dismisses when the text field loses focus or the user taps outside
  - Style: use `.background(.regularMaterial)` with rounded corners and shadow, matching platform conventions
  - Limit to 5-8 visible suggestions with scroll

### Step 3: Integrate Autocomplete into `TransactionDetailView`

The detail view is the primary editing surface (used for both new and existing transactions in the split-view layout). This is where autocomplete adds the most value.

- **`Features/Transactions/Views/TransactionDetailView.swift`**:
  - Accept a `TransactionStore` (or pass the repository) to access `fetchPayeeSuggestions`
  - Replace the plain `TextField("Payee", text: $payee)` with a `TextField` plus `PayeeSuggestionOverlay`
  - On payee text change, call `store.fetchPayeeSuggestions(prefix: payee)` (debounced, handled by the store)
  - On suggestion selection:
    1. Set `payee` to the selected string
    2. Call `store.fetchTransactionForAutofill(payee:)` to get the most recent transaction
    3. If found, auto-fill `categoryId`, `amountText`, `type`, and `toAccountId` from that transaction
    4. Clear suggestions
  - The auto-fill should NOT overwrite fields the user has already manually set. On a new transaction (amount is 0, category is nil), auto-fill all. On an existing transaction, only auto-fill if the current values match the original transaction's values (i.e., user hasn't changed them).

### Step 4: Integrate Autocomplete into `TransactionFormView`

The form view is used for the sheet-based create/edit flow. Apply the same pattern.

- **`Features/Transactions/Views/TransactionFormView.swift`**:
  - Accept a `TransactionStore` or repository for fetching suggestions
  - Same integration as TransactionDetailView: suggestion overlay on the payee field, auto-fill on selection

### Step 5: Contract Tests for `fetchPayeeSuggestions`

Ensure both backends correctly implement the method.

- **`MoolahTests/Domain/TransactionRepositoryContractTests.swift`**: Add tests:
  - Empty prefix returns empty results
  - Prefix matches are case-insensitive
  - Only non-empty, non-nil payees are returned
  - Results are deduplicated (same payee from multiple transactions appears once)
  - Results are sorted alphabetically

- **`MoolahTests/Backends/RemoteTransactionRepositoryTests.swift`**: Add fixture test for the payee filter query param (this partially exists as `testPayeeFilterParam`)

### Step 6: Polish and Accessibility

- **VoiceOver**: Announce suggestions count when the dropdown appears ("5 payee suggestions"). Mark each suggestion as a button.
- **Keyboard navigation (macOS)**: Arrow down from the text field enters the suggestion list. Enter/Return selects. Escape dismisses.
- **Dynamic Type**: Suggestion rows must scale with Dynamic Type.
- **Dismiss behavior**: Tapping outside the suggestion overlay dismisses it. Pressing Tab moves to the next field and dismisses.

## Files Modified (estimated)

| File | Change |
|------|--------|
| `Features/Transactions/TransactionStore.swift` | Add `payeeSuggestions`, `fetchPayeeSuggestions`, `fetchTransactionForAutofill`, `clearPayeeSuggestions` |
| `Features/Transactions/Views/PayeeSuggestionOverlay.swift` | **New** -- reusable suggestion dropdown component |
| `Features/Transactions/Views/TransactionDetailView.swift` | Add suggestion overlay to payee field, auto-fill on selection |
| `Features/Transactions/Views/TransactionFormView.swift` | Add suggestion overlay to payee field, auto-fill on selection |
| `MoolahTests/Features/TransactionStoreTests.swift` | Tests for suggestion fetching and autofill |
| `MoolahTests/Domain/TransactionRepositoryContractTests.swift` | Contract tests for `fetchPayeeSuggestions` |
| `project.yml` | Add new `PayeeSuggestionOverlay.swift` to sources (if needed -- xcodegen globs may handle it) |

## Verification

1. `just build-mac` -- compiles without warnings
2. `just test` -- all existing tests pass + new tests pass
3. Manual: create a new transaction, type a payee prefix that matches existing transactions, verify suggestions appear
4. Manual: select a suggestion, verify category/amount/type are auto-filled from the most recent matching transaction
5. Manual: verify suggestions dismiss when tapping outside or pressing Escape
6. Manual: verify VoiceOver announces suggestions on both macOS and iOS
7. Manual: verify keyboard navigation works in the suggestion list on macOS
8. `mcp__xcode__XcodeListNavigatorIssues` with severity "warning" -- no new warnings
