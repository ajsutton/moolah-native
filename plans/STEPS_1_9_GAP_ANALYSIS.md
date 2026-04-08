# Steps 1-9 Feature Parity Gap Analysis

**Date:** 2026-04-08
**Scope:** Steps 1-9 of NATIVE_APP_PLAN.md
**Comparison:** moolah-native vs. moolah-server API & moolah web app

---

## Executive Summary

**Overall Status:** Steps 1-9 have achieved ~75% feature parity with the web application. Core CRUD operations and viewing are implemented across all domains (Accounts, Transactions, Categories, Earmarks, Scheduled Transactions). However, critical management features and UI polish items are missing.

**Gap Summary:**
- **5 Critical gaps** (blocking full functionality)
- **12 Important gaps** (significantly diminish UX)
- **8 Nice-to-have gaps** (polish and convenience features)

**Key Findings:**
1. **Account Management (Step 13):** Completely missing CRUD operations (create/edit/delete/reorder accounts)
2. **Scheduled Transactions (Step 9):** UI for creating/editing recurrence is missing; pay action incomplete
3. **Transaction Filtering:** Missing amount range filters, transaction type filter, and "notes" search
4. **Earmark Management:** Budget allocation UI exists but earmark reordering is missing
5. **Category Management:** Fully functional
6. **Investment Tracking (Step 12):** Not yet implemented (planned for Step 12)
7. **Analysis Dashboard (Step 10):** Not yet implemented (planned for Step 10)

---

## Step 1: Project Scaffolding & CI

### Implemented ✅
- Xcode project structure with iOS 26+ and macOS 26+ targets
- Swift Testing framework integrated
- Domain layer (Models + Repository protocols)
- Backend abstraction (`BackendProvider`, `InMemoryBackend`, `RemoteBackend`)
- Git repository with `.gitignore`
- `justfile` with build/test targets
- CI workflow (GitHub Actions)

### Missing ❌
- None identified (Step 1 is complete)

### Impact
- N/A

---

## Step 2: Authentication

### Implemented ✅
- `UserProfile` domain model
- `AuthProvider` protocol
- `BackendProvider` with `auth` property
- `InMemoryAuthProvider` for tests/previews
- `RemoteAuthProvider` with Google Sign-In SDK
- `AuthStore` with loading/signedOut/signedIn states
- `WelcomeView` with sign-in UI
- `UserMenuView` with avatar, name, sign-out button
- Cookie-based session management (`CookieKeychain`)

### Missing ❌
- **None** (Authentication is complete)

### Impact
- N/A

---

## Step 3: Account List (Read-Only)

### Implemented ✅
- `Account` domain model with `AccountType` enum
- `AccountRepository` protocol with `fetchAll()`
- `InMemoryAccountRepository` and `RemoteAccountRepository`
- `AccountDTO` with server JSON mapping
- `AccountStore` with computed totals (currentTotal, investmentTotal, netWorth)
- `SidebarView` with account grouping (Current Accounts, Investments)
- `AccountRowView` with name, balance, type icon

### Missing ❌

#### 1. Hidden Accounts Toggle
**Gap:** Accounts have an `isHidden` field but no UI to show/hide accounts in the sidebar.

**Server Support:** Yes — `PUT /api/accounts/{id}` accepts `hidden: boolean`

**Impact:** Important — Users cannot declutter their sidebar by hiding closed/inactive accounts.

**Required:**
- Add "Show Hidden Accounts" toggle to sidebar footer or settings
- Filter `accounts.ordered` by `!isHidden` unless toggle is on
- Visual distinction for hidden accounts (e.g., gray text, italic font)

**Implementation Steps:**
1. Add `@State var showHiddenAccounts = false` to `SidebarView`
2. Update account filtering logic in `AccountStore.currentAccounts` and `AccountStore.investmentAccounts`
3. Add toggle UI in sidebar (below account sections)
4. Persist toggle state in `UserDefaults` (or app preferences)
5. Test: Hide an account → verify it disappears from sidebar → enable toggle → verify it reappears

**Estimate:** 2 hours

---

## Step 4: Transaction List (Read-Only)

### Implemented ✅
- `Transaction` domain model with `TransactionType`, `RecurPeriod`, `TransactionFilter`
- `TransactionPage` with `priorBalance` for running balance calculation
- `TransactionWithBalance` paired with running balance
- `TransactionRepository` protocol with `fetch(filter:page:pageSize:)`
- `InMemoryTransactionRepository` and `RemoteTransactionRepository`
- `TransactionDTO` with server JSON mapping
- `TransactionStore` with pagination, optimistic updates, rollback
- `TransactionListView` with infinite scroll
- `TransactionRowView` showing payee, date, amount (colored by type), running balance (optional)
- Filter by `accountId`, `dateRange`, `scheduled`, `categoryIds`, `earmarkId`, `payee`

### Missing ❌

#### 1. Amount Range Filter
**Gap:** No ability to filter transactions by amount (e.g., "show transactions > $100" or "between $50 and $200").

**Server Support:** No — The server's `transactionSearchOptions.js` does not support amount filtering.

**Impact:** Nice-to-have — Advanced filtering for finding large transactions or specific amounts.

**Required:**
- **Server-side work (out of scope):** Add `minAmount` and `maxAmount` query params to `GET /transactions`
- **Domain layer:** Extend `TransactionFilter` with `minAmount: MonetaryAmount?` and `maxAmount: MonetaryAmount?`
- **UI:** Add amount range fields to `TransactionFilterView` (two `TextField` inputs with currency formatting)
- **Backend:** Implement filtering logic in `InMemoryTransactionRepository` and `RemoteTransactionRepository`

**Estimate:** 4 hours (2 hours server-side, 2 hours native app)

---

#### 2. Transaction Type Filter
**Gap:** No ability to filter by transaction type (income, expense, transfer).

**Server Support:** Yes — `transactionType` query param exists in `transactionSearchOptions.js`

**Impact:** Important — Users cannot quickly view "all income" or "all transfers".

**Required:**
1. Extend `TransactionFilter` to include `transactionType: TransactionType?`
2. Add picker to `TransactionFilterView`:
   ```swift
   Picker("Type", selection: $selectedTransactionType) {
     Text("All Types").tag(nil as TransactionType?)
     Text("Income").tag(TransactionType.income as TransactionType?)
     Text("Expense").tag(TransactionType.expense as TransactionType?)
     Text("Transfer").tag(TransactionType.transfer as TransactionType?)
   }
   ```
3. Update `RemoteTransactionRepository` to include `transactionType` query param
4. Update `InMemoryTransactionRepository` to filter by type
5. Add tests verifying type filtering works in isolation and with other filters

**Estimate:** 2 hours

---

#### 3. Search in Notes
**Gap:** The `payee` filter is a substring search, but there's no equivalent for searching transaction notes.

**Server Support:** No — The server does not support `notes` search.

**Impact:** Nice-to-have — Power users often add important details to notes and want to search them.

**Required:**
- **Server-side work (out of scope):** Add `notes` query param with substring search
- Extend `TransactionFilter` with `notes: String?`
- Add `TextField("Search notes…", text: $notesText)` to `TransactionFilterView`
- Update repositories to support notes filtering

**Estimate:** 3 hours (1 hour server-side, 2 hours native app)

---

#### 4. Exclude Categories Filter
**Gap:** Current category filter is "include these categories". No way to exclude categories (e.g., "show all except Groceries").

**Server Support:** No

**Impact:** Nice-to-have — Useful for analysis (e.g., "all spending except rent").

**Required:**
- Extend `TransactionFilter` with `excludeCategoryIds: Set<UUID>?`
- Add "Exclude" toggle to category list in `TransactionFilterView`
- Update filtering logic in repositories

**Estimate:** 3 hours

---

## Step 5: Create & Edit Transactions

### Implemented ✅
- `TransactionRepository` gains `create`, `update`, `delete`, `fetchPayeeSuggestions`
- `CategoryRepository` with `fetchAll()` for category picker
- `InMemoryBackend` and `RemoteBackend` extended with mutation endpoints
- `TransactionFormView` with full CRUD UI:
  - Type selection (income/expense/transfer)
  - Payee autocomplete (planned, not yet visible)
  - Amount input
  - Date picker
  - Account picker
  - Transfer destination picker (when type == transfer)
  - Category picker
  - Earmark picker
  - Notes field
  - Recurrence fields (period + frequency) — **UI exists but read-only**
  - Delete button with confirmation
- `TransactionStore` with `create`, `update`, `delete` methods, optimistic updates, rollback
- Transfer transactions create two entries (one per account) — handled by server

### Missing ❌

#### 1. Payee Autocomplete Implementation
**Gap:** `TransactionFormView` has a payee `TextField` but no autocomplete dropdown. The repository method `fetchPayeeSuggestions(prefix:)` is defined but not called from the UI.

**Server Support:** No — The server does not have a payee suggestions endpoint.

**Impact:** Important — Typing the same payee names repeatedly is tedious; autocomplete is a major UX enhancement.

**Required:**

**Option A: Client-Side Autocomplete (Recommended)**
1. `InMemoryTransactionRepository` and `RemoteTransactionRepository` implement `fetchPayeeSuggestions(prefix:)` by:
   - Fetching all transactions (or a cached list of transactions)
   - Extracting unique `payee` values
   - Filtering by `prefix.lowercased()` substring
   - Returning top 10 matches
2. In `TransactionFormView`, add an autocomplete dropdown below the payee field:
   ```swift
   @State private var payeeSuggestions: [String] = []

   TextField("Payee", text: $payee)
     .onChange(of: payee) { _, newValue in
       Task {
         payeeSuggestions = await fetchSuggestions(for: newValue)
       }
     }

   if !payeeSuggestions.isEmpty {
     VStack(alignment: .leading) {
       ForEach(payeeSuggestions, id: \.self) { suggestion in
         Button(suggestion) {
           payee = suggestion
           payeeSuggestions = []
         }
       }
     }
   }
   ```
3. Test with common payee names (e.g., "Coles", "Woolworths") and verify suggestions appear after typing 2-3 characters

**Option B: Server-Side Autocomplete (Future Enhancement)**
- Add `GET /api/transactions/payees?prefix=<string>` endpoint to moolah-server
- Use SQL `SELECT DISTINCT payee FROM transactions WHERE payee LIKE ? ORDER BY payee` query
- Native app calls this endpoint instead of local filtering

**Estimate:** 3 hours (client-side), 5 hours (server-side + client)

---

#### 2. Recurrence UI (Scheduled Transactions)
**Gap:** `TransactionFormView` stores `recurPeriod` and `recurEvery` when editing existing scheduled transactions, but provides no UI to create or modify recurrence settings.

**Status:** Partially addressed in SCHEDULED_TRANSACTIONS_GAP_ANALYSIS.md

**Impact:** Critical — Users cannot create scheduled transactions from the native app.

**Required:**
- See detailed plan in SCHEDULED_TRANSACTIONS_GAP_ANALYSIS.md, Phase 1, Task 3: "Add recurrence UI to TransactionFormView"
- Toggle for "Repeat" (on = recurring, off = one-time or non-scheduled)
- When toggle is on, show:
  - "Every" number field (min 1)
  - "Period" picker (Day, Week, Month, Year)
- Validation: both period and frequency must be set if toggle is on
- Update `recurPeriod` and `recurEvery` on save

**Estimate:** 4 hours (covered in Step 9 gap analysis)

---

#### 3. Duplicate Transaction Action
**Gap:** No way to duplicate an existing transaction (useful for recurring expenses entered manually).

**Server Support:** N/A (client-side only)

**Impact:** Nice-to-have — Saves time when entering similar transactions.

**Required:**
1. Add "Duplicate" button to `TransactionDetailView` or context menu in `TransactionRowView`
2. On tap:
   - Create a copy of the transaction with a new UUID
   - Set date to today
   - Clear `recurPeriod` and `recurEvery` (don't duplicate scheduled transactions)
   - Open `TransactionFormView` with the copied transaction in "create" mode
3. Test: Duplicate a transaction → verify all fields are copied except ID and date

**Estimate:** 2 hours

---

#### 4. Split Transactions
**Gap:** No support for splitting a single transaction across multiple categories (e.g., one grocery receipt with food + household items).

**Server Support:** No — The server transaction model has a single `categoryId`.

**Impact:** Important — Common use case in personal finance apps.

**Required:**
- **Major feature requiring domain model changes** — Out of scope for current steps
- Would require:
  - New `TransactionSplit` domain model with `categoryId`, `earmarkId`, `amount`
  - `Transaction.splits: [TransactionSplit]?` field
  - Server schema changes
  - UI for adding/editing splits in `TransactionFormView`
- **Recommendation:** Defer to a future step (after Step 14)

**Estimate:** 20+ hours (server + native app)

---

#### 5. Transaction Attachments/Receipts
**Gap:** No ability to attach images (receipts, invoices) to transactions.

**Server Support:** No

**Impact:** Nice-to-have — Useful for expense tracking and audits.

**Required:**
- New domain model: `TransactionAttachment` with `id`, `transactionId`, `filename`, `url`
- Server endpoints: `POST /api/transactions/{id}/attachments/`, `GET /api/transactions/{id}/attachments/`, `DELETE /api/transactions/{id}/attachments/{attachmentId}`
- Native app: File picker, image display, upload/download logic
- **Recommendation:** Defer to post-Step 14 (significant feature)

**Estimate:** 30+ hours

---

## Step 6: All Transactions & Filtering

### Implemented ✅
- `AllTransactionsView` (no account scoping)
- `TransactionFilterView` with:
  - Date range picker (start/end with toggle)
  - Account picker
  - Earmark picker
  - Category multi-select (toggles for each category)
  - Payee text field (substring search)
  - Scheduled picker (all/scheduled-only/non-scheduled)
  - Clear All button
- Filter badge showing active filter count (if implemented in UI)
- All filters work in isolation and in combination (verified via tests)

### Missing ❌

#### 1. Transaction Type Filter
**Gap:** Same as Step 4 gap #2 (covered above).

**Impact:** Important

**Estimate:** 2 hours

---

#### 2. Amount Range Filter
**Gap:** Same as Step 4 gap #1 (covered above).

**Impact:** Nice-to-have

**Estimate:** 4 hours

---

#### 3. Filter Presets / Saved Filters
**Gap:** No ability to save commonly used filters (e.g., "Last month groceries", "All income this year").

**Server Support:** No

**Impact:** Nice-to-have — Power user feature.

**Required:**
- New domain model: `SavedFilter` with `id`, `name`, `filter: TransactionFilter`
- Store locally (UserDefaults or SwiftData)
- Add "Save Filter" button to `TransactionFilterView`
- Add "Saved Filters" picker at top of filter view
- **Recommendation:** Defer to post-Step 14

**Estimate:** 8 hours

---

#### 4. Active Filter Badge/Indicator
**Gap:** No visual indicator on "All Transactions" view showing that a filter is active.

**Impact:** Important — Users may forget they've applied a filter and be confused by missing transactions.

**Required:**
1. Add computed property to `TransactionStore`: `var isFiltered: Bool { currentFilter != TransactionFilter() }`
2. In `AllTransactionsView` toolbar, show badge or "Filtered" text when `isFiltered == true`
3. Tap badge to open `TransactionFilterView` or clear filter
4. Example:
   ```swift
   ToolbarItem {
     if transactionStore.isFiltered {
       Button {
         showFilterSheet = true
       } label: {
         Label("Filtered", systemImage: "line.3.horizontal.decrease.circle.fill")
           .foregroundStyle(.blue)
       }
     } else {
       Button {
         showFilterSheet = true
       } label: {
         Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
       }
     }
   }
   ```

**Estimate:** 1 hour

---

## Step 7: Category Management

### Implemented ✅
- `Category` domain model with `parentId` for hierarchy
- `Categories` lookup structure with `roots` and `children(of:)`
- `CategoryRepository` with `create`, `update`, `delete(id:withReplacement:)`
- `InMemoryCategoryRepository` and `RemoteCategoryRepository`
- `CategoryStore` with full CRUD
- `CategoriesView` with:
  - Hierarchical tree (DisclosureGroup for parent categories)
  - Search bar
  - "Add Category" button
  - Context menu for editing
- `CategoryDetailView` with:
  - Rename field
  - Delete button with replacement category picker
  - Confirmation dialog
- Tests for tree building, CRUD cycle, replacement on delete

### Missing ❌

#### None Identified ✅

**Status:** Category management is feature-complete for Steps 1-9.

**Future Enhancements (post-Step 14):**
- Category icons/colors
- Category budgets (monthly spending limits)
- Category archiving (hide instead of delete)
- Default category for new transactions

---

## Step 8: Earmarks

### Implemented ✅
- `Earmark` domain model with `balance`, `saved`, `spent`, `isHidden`, `position`, `savingsGoal`, `savingsStartDate`, `savingsEndDate`
- `EarmarkBudgetItem` domain model
- `EarmarkRepository` with `fetchAll`, `create`, `update`, `fetchBudget`, `updateBudget`
- `InMemoryEarmarkRepository` and `RemoteEarmarkRepository`
- `EarmarkStore` with CRUD and budget operations
- `EarmarksView` in sidebar
- `EarmarkDetailView` with:
  - Overview panel (balance, saved, spent)
  - Savings goal progress bar
  - Savings date range
  - Transaction list scoped to earmark
  - Edit button
- `TransactionFormView` includes earmark picker
- Tests for savings goal progress, budget allocation, earmark filter

### Missing ❌

#### 1. Earmark Budget Allocation UI
**Gap:** `EarmarkRepository.fetchBudget` and `updateBudget` are implemented, but there's no UI to view or edit the budget allocation (which categories belong to which earmark).

**Server Support:** Yes — `GET /api/earmarks/{id}/budget/` and `PUT /api/earmarks/{earmarkId}/budget/{categoryId}/`

**Impact:** Important — Budget allocation is a core earmark feature.

**Required:**
1. Add a "Budget" tab or section to `EarmarkDetailView`
2. Fetch budget items: `earmarkStore.loadBudget(earmarkId: earmark.id)`
3. Display list of categories with allocated amounts
4. Allow adding/editing/removing budget items
5. UI mockup:
   ```
   Budget Allocation
   ┌────────────────────────────────────┐
   │ Groceries                  $400.00 │
   │ Transport                  $150.00 │
   │ Entertainment               $50.00 │
   │ ────────────────────────────────── │
   │ Total                      $600.00 │
   │ [Add Category]                     │
   └────────────────────────────────────┘
   ```
6. On save, call `earmarkStore.updateBudget(earmarkId:items:)`

**Estimate:** 6 hours

---

#### 2. Earmark Reordering
**Gap:** Earmarks have a `position` field, but there's no drag-and-drop UI to reorder them in the sidebar.

**Server Support:** Yes — `PUT /api/earmarks/{id}` accepts `position: Int`

**Impact:** Nice-to-have — Users may want to prioritize certain earmarks visually.

**Required:**
1. Add `.onMove` modifier to earmark list in `SidebarView`
2. Update earmark positions on move
3. Call `earmarkStore.update(updatedEarmark)` for each moved earmark
4. Example:
   ```swift
   ForEach(earmarks.ordered) { earmark in
     EarmarkRowView(earmark: earmark)
   }
   .onMove { from, to in
     Task {
       await earmarkStore.reorder(from: from, to: to)
     }
   }
   ```

**Estimate:** 3 hours

---

#### 3. Earmark Transfers
**Gap:** No UI to transfer funds between earmarks (e.g., move $100 from "Emergency Fund" to "Vacation Fund").

**Server Support:** No — The server has no dedicated earmark transfer endpoint. The web app likely creates two transactions (one negative, one positive) with matching `earmarkId`s.

**Impact:** Nice-to-have — Useful for reallocating savings.

**Required:**
1. Add "Transfer to Earmark" button in `EarmarkDetailView`
2. Show sheet with:
   - Destination earmark picker
   - Amount field
   - Notes (optional)
3. On save:
   - Create two transactions:
     - Transaction 1: `type: .expense`, `earmarkId: sourceEarmark.id`, `amount: -transferAmount`
     - Transaction 2: `type: .income`, `earmarkId: destinationEarmark.id`, `amount: +transferAmount`
   - Both transactions should have matching `payee` (e.g., "Transfer: Earmark → Earmark") and `notes`
4. Test: Transfer $50 from Earmark A to Earmark B → verify both earmark balances update correctly

**Estimate:** 5 hours

---

#### 4. Automatic Earmark Allocation Rules
**Gap:** No way to define rules like "automatically allocate 10% of all income to Emergency Fund".

**Server Support:** No

**Impact:** Nice-to-have — Power user feature for automatic budgeting.

**Required:**
- New domain model: `EarmarkAllocationRule` with `earmarkId`, `percentage`, `categoryFilter`, etc.
- Complex logic for applying rules on transaction creation
- **Recommendation:** Defer to post-Step 14 (significant feature)

**Estimate:** 20+ hours

---

#### 5. Hidden Earmarks Toggle
**Gap:** Same issue as accounts — earmarks have `isHidden` but no toggle to show/hide them.

**Impact:** Important

**Required:** Same solution as account hidden toggle (see Step 3, gap #1).

**Estimate:** 1 hour

---

## Step 9: Upcoming / Scheduled Transactions

### Implemented ✅
- `RecurPeriod` enum (once/day/week/month/year)
- `Transaction.recurPeriod` and `Transaction.recurEvery` fields
- `Transaction.isScheduled` and `Transaction.isRecurring` computed properties
- `Transaction.nextDueDate()` method (calendar-based date calculation)
- `Transaction.validate()` method (validates recurrence fields)
- `TransactionFilter.scheduled: Bool?`
- Filtering by `scheduled` in `InMemoryTransactionRepository` and `RemoteTransactionRepository`
- `UpcomingView` with:
  - Fetches scheduled transactions
  - Splits into "Overdue" and "Upcoming" sections
  - Displays recurrence description (e.g., "Every 2 weeks")
  - Pay button on each row
  - Empty state
- Pay action (partial):
  - Creates a non-scheduled copy with today's date
  - **Does NOT update/delete the original scheduled transaction** (bug)

### Missing ❌

#### 1. Recurrence UI in TransactionFormView
**Gap:** No UI to set `recurPeriod` and `recurEvery` when creating or editing transactions.

**Status:** Covered in SCHEDULED_TRANSACTIONS_GAP_ANALYSIS.md, Phase 1, Task 3.

**Impact:** Critical — Cannot create scheduled transactions.

**Estimate:** 4 hours (see scheduled gap analysis)

---

#### 2. Complete Pay Action Implementation
**Gap:** Paying a scheduled transaction creates a new transaction but does not advance the scheduled transaction's date (recurring) or delete it (one-time).

**Status:** Covered in SCHEDULED_TRANSACTIONS_GAP_ANALYSIS.md, Phase 1, Task 4.

**Impact:** Critical — Scheduled transactions don't behave correctly after being paid.

**Required:**
- Extend `TransactionStore.payTransaction(_:)` to:
  1. Create paid transaction (already done)
  2. If `recurPeriod == .once`: delete the original scheduled transaction
  3. Else: calculate next due date and update the original scheduled transaction's `date`
- Full logic in SCHEDULED_TRANSACTIONS_GAP_ANALYSIS.md

**Estimate:** 3 hours (see scheduled gap analysis)

---

#### 3. Skip Scheduled Transaction Occurrence
**Gap:** No way to skip a single occurrence of a recurring transaction (e.g., "skip this month's rent payment").

**Server Support:** No

**Impact:** Nice-to-have — Useful for one-off situations (e.g., rent paid by someone else).

**Required:**
1. Add "Skip" button to `UpcomingView` row
2. On tap:
   - Calculate next occurrence using `nextDueDate()`
   - Update scheduled transaction's `date` to next occurrence (without creating a paid transaction)
3. Confirmation dialog: "Skip [payee] on [date]?"
4. Test: Skip a monthly recurring transaction → verify it advances by one month

**Estimate:** 2 hours

---

#### 4. Batch Pay (Pay Multiple Scheduled Transactions)
**Gap:** No way to pay multiple scheduled transactions at once (e.g., "pay all overdue bills").

**Server Support:** No

**Impact:** Nice-to-have — Convenience feature for users with many scheduled transactions.

**Required:**
1. Add "Edit" button to `UpcomingView` toolbar
2. Enable multi-select mode (checkboxes appear on rows)
3. Add "Pay Selected" button to toolbar
4. On tap:
   - Confirm with dialog showing total count and amount
   - Loop through selected transactions and call `payTransaction(_:)` for each
   - Show progress indicator
5. Test: Select 5 scheduled transactions → pay all → verify all advance to next occurrence

**Estimate:** 5 hours

---

#### 5. End Date for Recurring Transactions
**Gap:** No way to set an end date for recurring transactions (e.g., "monthly rent until Dec 2026").

**Server Support:** No — The server transaction model has no `recurEndDate` field.

**Impact:** Nice-to-have — Users with fixed-term recurring expenses (leases, subscriptions).

**Required:**
- Extend `Transaction` domain model with `recurEndDate: Date?`
- Server schema migration
- UI in `TransactionFormView`: "End Date" picker (optional)
- Logic: when paying, check if next occurrence is after `recurEndDate` → if so, delete instead of update
- **Recommendation:** Defer to post-Step 14

**Estimate:** 8 hours (server + native)

---

#### 6. Forecasting Scheduled Transactions (Analysis Dashboard)
**Gap:** The Analysis dashboard (Step 10, not yet implemented) will need to show forecasted balances based on scheduled transactions. The server supports this via `GET /api/analysis/dailyBalances?forecastUntil=<date>`, but no native app code exists yet.

**Status:** Covered in SCHEDULED_TRANSACTIONS_GAP_ANALYSIS.md, Phase 2.

**Impact:** Medium — Important for cash flow planning.

**Required:**
- See SCHEDULED_TRANSACTIONS_GAP_ANALYSIS.md for full plan
- Will be implemented in Step 10 (Analysis Dashboard)

**Estimate:** 9 hours (see scheduled gap analysis)

---

## Step 10: Analysis Dashboard

### Implemented ❌
**Status:** Step 10 is NOT implemented yet (planned but not started).

### Missing (Entire Step)

The Analysis Dashboard is a major feature requiring:
1. **Domain Models:**
   - `DailyBalance` (date, balance, isForecast)
   - `ExpenseBreakdown` (categoryId, amount, percentage)
   - `MonthlyIncomeExpense` (month, income, expense)

2. **AnalysisRepository Protocol:**
   ```swift
   protocol AnalysisRepository: Sendable {
     func fetchDailyBalances(dateRange:includeForecast:) async throws -> [DailyBalance]
     func fetchExpenseBreakdown(dateRange:) async throws -> [ExpenseBreakdown]
     func fetchIncomeAndExpense(dateRange:) async throws -> [MonthlyIncomeExpense]
   }
   ```

3. **Backend Implementations:**
   - `InMemoryAnalysisRepository`: Compute from in-memory transactions
   - `RemoteAnalysisRepository`: Call server endpoints (`/api/analysis/dailyBalances`, `/api/analysis/expenseBreakdown`, `/api/analysis/incomeAndExpense`)

4. **UI:**
   - `AnalysisView` with:
     - Net-worth area chart (Swift Charts)
     - Expense breakdown pie chart
     - Income/expense table
     - Upcoming transactions widget (short-term, next 14 days)
   - Financial-year picker + custom date range selector

5. **Tests:**
   - Balances ordered by date
   - Forecast flagged correctly
   - Breakdown percentages sum to 100%
   - Chart rendering with zero data and extreme values

**Impact:** Critical — The dashboard is a primary user-facing feature.

**Estimate:** 20 hours (full Step 10 implementation)

---

## Step 11: Reports

### Implemented ❌
**Status:** Step 11 is NOT implemented yet (planned but not started).

### Missing (Entire Step)

Income and expense breakdown reports by category for any date range. Reuses `AnalysisRepository`.

**Required:**
- `ReportsView` with:
  - Date range selector
  - Income by category table (with subcategory rows)
  - Expense by category table (with subcategory rows)
  - Totals row
- Hierarchical category display (parent → children)
- Export option (CSV, PDF) — nice-to-have

**Impact:** Important — Users need detailed category breakdowns for budgeting.

**Estimate:** 8 hours

---

## Step 12: Investment Tracking

### Implemented ❌
**Status:** Step 12 is NOT implemented yet (planned but not started).

### Missing (Entire Step)

Investment accounts can show value history and allow manual value entries.

**Required:**
1. **Domain Model:**
   - `InvestmentValue` (accountId, date, value)

2. **InvestmentRepository Protocol:**
   ```swift
   protocol InvestmentRepository: Sendable {
     func fetchValues(accountId:page:) async throws -> [InvestmentValue]
     func setValue(_:) async throws -> InvestmentValue
     func deleteValue(id:) async throws
   }
   ```

3. **Backend Implementations:**
   - `InMemoryInvestmentRepository`
   - `RemoteInvestmentRepository` calling `/api/accounts/{id}/values/`

4. **UI:**
   - `InvestmentValuesView` (inside `AccountDetailView` for investment accounts)
   - Line chart showing value over time
   - List of manual entries with date and value
   - "Add Value" button
   - Edit/delete actions

5. **Tests:**
   - Pagination of values
   - Add/delete cycle
   - Chart rendering

**Impact:** Important — Investment tracking is a core feature for users with investment accounts.

**Estimate:** 12 hours

---

## Step 13: Account Management (Create / Edit / Reorder)

### Implemented ❌
**Status:** Step 13 is NOT implemented yet.

### Missing (Entire Step)

#### 1. Create Account
**Gap:** No UI to create new accounts. The server supports `POST /api/accounts/`.

**Impact:** Critical — Users cannot add accounts (e.g., new bank account, credit card).

**Required:**
1. Extend `AccountRepository` protocol:
   ```swift
   func create(_ account: Account) async throws -> Account
   ```
2. Implement in `InMemoryAccountRepository` and `RemoteAccountRepository`
3. Create `CreateAccountSheet` view with:
   - Name field
   - Type picker (bank, credit card, asset, investment)
   - Opening balance field (optional, defaults to 0)
   - Opening balance date (optional, defaults to today)
4. Add "Add Account" button to sidebar or accounts list
5. On save:
   - Call `accountStore.create(newAccount)`
   - Server creates account + opening balance transaction
6. Test: Create account → verify it appears in sidebar with correct balance

**Estimate:** 5 hours

---

#### 2. Edit Account
**Gap:** No UI to edit account name, type, or toggle hidden status. The server supports `PUT /api/accounts/{id}`.

**Impact:** Critical — Users cannot rename accounts or change account type.

**Required:**
1. Extend `AccountRepository` protocol:
   ```swift
   func update(_ account: Account) async throws -> Account
   ```
2. Implement in backends
3. Create `EditAccountSheet` view (similar to create, but pre-filled)
4. Add "Edit" action to account context menu or detail view
5. On save, call `accountStore.update(modifiedAccount)`
6. Test: Edit account name → verify change persists and syncs to server

**Estimate:** 4 hours

---

#### 3. Delete Account
**Gap:** No UI to delete accounts. Server does not have a delete endpoint (may be intentional to preserve transaction history).

**Impact:** Important — Users may want to remove closed accounts.

**Considerations:**
- Server-side: Need to decide if accounts can be deleted or only hidden
- If deleting is allowed, need to handle transactions linked to the account (cascade delete? block deletion?)
- **Recommendation:** Initially, only support hiding accounts (set `isHidden = true`). Add delete later if required.

**Estimate:** 2 hours (hide), 8 hours (full delete with transaction handling)

---

#### 4. Reorder Accounts
**Gap:** Accounts have a `position` field, but no drag-and-drop UI to reorder them.

**Impact:** Nice-to-have — Users may want to prioritize certain accounts visually.

**Required:**
1. Add `.onMove` modifier to account list in `SidebarView`
2. Update account positions on move
3. Call `accountStore.update(account)` for each moved account
4. Test: Drag account from position 0 to position 3 → verify order persists

**Estimate:** 3 hours

---

#### 5. Account Colors/Icons
**Gap:** No custom colors or icons for accounts. Currently uses generic `creditcard`/`banknote` SF Symbols.

**Impact:** Nice-to-have — Improves visual distinction between accounts.

**Required:**
- Extend `Account` model with `color: String?` and `iconName: String?`
- Server schema migration
- UI in account edit sheet: color picker + SF Symbol picker
- Display custom color/icon in `AccountRowView`
- **Recommendation:** Defer to post-Step 14

**Estimate:** 8 hours

---

#### 6. Multi-Currency Support
**Gap:** All amounts use `Currency.defaultCurrency` (AUD). No support for multiple currencies.

**Impact:** Important — Users with foreign accounts or international transactions cannot track them accurately.

**Required:**
- Major feature requiring:
  - Per-account currency (extend `Account` model)
  - Currency conversion rates (new domain model + repository)
  - UI for selecting currency on account creation
  - Display amounts in account's currency in transaction lists
  - Convert to base currency for net-worth calculations
- **Recommendation:** Defer to post-Step 14 (or separate project)

**Estimate:** 30+ hours

---

## Cross-Cutting Gaps (Apply to Multiple Steps)

### 1. Bulk Operations (Transactions)
**Gap:** No ability to select multiple transactions and perform bulk actions (delete, categorize, change account, change earmark).

**Impact:** Important — Power users with many transactions need bulk editing.

**Required:**
1. Add "Edit" mode to `AllTransactionsView` and account transaction lists
2. Show checkboxes on transaction rows
3. Add toolbar with bulk actions:
   - Delete selected
   - Change category
   - Change earmark
   - Move to account (for transfers)
4. Confirmation dialogs for destructive actions
5. Progress indicator for large batches
6. Test: Select 20 transactions → delete all → verify they disappear

**Estimate:** 8 hours

---

### 2. Undo/Redo
**Gap:** No undo for destructive operations (delete transaction, delete category, etc.).

**Impact:** Nice-to-have — Prevents accidental data loss.

**Required:**
- Implement command pattern for mutations
- Store undo stack (max 10-20 commands)
- Add "Undo" button to toolbar or Cmd+Z shortcut (macOS)
- Test: Delete transaction → undo → verify it reappears

**Estimate:** 10 hours

---

### 3. Data Export
**Gap:** No way to export transactions/accounts to CSV or JSON.

**Impact:** Important — Users may want to analyze data in Excel or migrate to another app.

**Required:**
1. Add "Export" menu item to app menu (macOS) or settings (iOS)
2. Show export dialog:
   - Format: CSV or JSON
   - Date range: all-time, this year, custom
   - Entities: transactions, accounts, categories, earmarks
3. Generate file and save to disk (macOS) or share sheet (iOS)
4. Test: Export last year's transactions to CSV → verify all fields are present

**Estimate:** 6 hours

---

### 4. Settings/Preferences
**Gap:** No settings screen. Potential settings:
- Default currency
- Default account for new transactions
- Show hidden accounts/earmarks toggle
- Theme (light/dark/auto)
- Keyboard shortcuts customization (macOS)

**Impact:** Nice-to-have — Most settings can be hardcoded for now.

**Required:**
- Create `SettingsView` (macOS) or settings section (iOS)
- Store preferences in `UserDefaults` or SwiftData
- Apply settings throughout app

**Estimate:** 4 hours

---

### 5. Keyboard Shortcuts (macOS)
**Gap:** Only basic shortcuts are implemented (Cmd+N for new transaction, Cmd+F for filter, Cmd+R for refresh). Missing:
- Cmd+E: Edit selected item
- Cmd+D: Duplicate transaction
- Delete: Delete selected item (with confirmation)
- Cmd+1/2/3: Switch between views (Accounts, Transactions, Categories)
- Cmd+,: Open settings (if implemented)

**Impact:** Important (macOS) — Power users rely on keyboard navigation.

**Required:**
- Add `.keyboardShortcut()` modifiers to all major actions
- Test all shortcuts don't conflict with system shortcuts

**Estimate:** 3 hours

---

### 6. Search Across All Entities
**Gap:** Search is limited to individual views (search categories, search transactions by payee). No global search across all entities.

**Impact:** Nice-to-have — Users may want to search for "Coles" and see accounts, transactions, and categories.

**Required:**
- Add global search field to toolbar
- Implement search logic across accounts, transactions, categories, earmarks
- Show results grouped by type
- Tap result to navigate to detail view
- **Recommendation:** Defer to post-Step 14

**Estimate:** 12 hours

---

### 7. Recent Items / Quick Access
**Gap:** No "recently viewed" or "favorites" section for quick access to frequently used accounts/earmarks.

**Impact:** Nice-to-have — Improves navigation for users with many accounts.

**Required:**
- Track recently viewed items in `UserDefaults` or SwiftData
- Add "Recent" section to sidebar or dashboard
- Limit to 5-10 items
- **Recommendation:** Defer to post-Step 14

**Estimate:** 4 hours

---

### 8. Offline Mode Enhancements
**Gap:** Step 14 mentions offline reads and write queue, but detailed implementation is missing. Current state:
- Offline reads: Not implemented (app shows errors when network is unavailable)
- Write queue: Not implemented (mutations fail immediately if offline)

**Impact:** Critical (mobile users) — App is unusable without network.

**Required:**
- Implement SwiftData cache for all entities
- Populate cache on successful fetch
- Serve stale cache when repository throws `BackendError.networkUnavailable`
- Queue mutations (create/update/delete) in SwiftData when offline
- Flush queue when connectivity returns
- Handle conflicts (server state changed while offline)
- **Full plan in Step 14**

**Estimate:** 20+ hours

---

### 9. Dark Mode Compliance
**Gap:** Style guide mandates dark mode support, but it's unclear if all views have been tested in dark mode.

**Impact:** Important — Poor dark mode experience drives users away.

**Required:**
- Audit all views in dark mode
- Fix any hardcoded colors (should use system colors only)
- Test with "Increase Contrast" accessibility setting
- Verify all charts/graphs work in dark mode

**Estimate:** 4 hours

---

### 10. Accessibility Audit
**Gap:** STYLE_GUIDE.md requires VoiceOver labels, keyboard navigation, and color contrast checks. Not clear if all views meet these requirements.

**Impact:** Critical (accessibility) — App must be usable by all users.

**Required:**
- Run VoiceOver on all major screens
- Add missing `.accessibilityLabel()` modifiers
- Test keyboard navigation (macOS): tab order, focus management
- Verify color contrast ratios with Xcode Accessibility Inspector
- Test with Dynamic Type at largest size
- **Recommendation:** Run UI review agent before shipping any view

**Estimate:** 8 hours (full audit + fixes)

---

## Summary Table: Gap Priorities

| Gap | Step | Impact | Estimate | Blocking? |
|-----|------|--------|----------|-----------|
| Account CRUD (create/edit/delete/reorder) | 13 | Critical | 14 hours | Yes |
| Recurrence UI in TransactionFormView | 9 | Critical | 4 hours | Yes |
| Complete Pay Action for Scheduled Transactions | 9 | Critical | 3 hours | Yes |
| Analysis Dashboard (entire step) | 10 | Critical | 20 hours | No (future step) |
| Investment Tracking (entire step) | 12 | Important | 12 hours | No (future step) |
| Payee Autocomplete | 5 | Important | 3-5 hours | No |
| Transaction Type Filter | 6 | Important | 2 hours | No |
| Earmark Budget Allocation UI | 8 | Important | 6 hours | No |
| Hidden Accounts/Earmarks Toggle | 3,8 | Important | 3 hours | No |
| Bulk Transaction Operations | All | Important | 8 hours | No |
| Active Filter Badge | 6 | Important | 1 hour | No |
| Data Export | All | Important | 6 hours | No |
| Offline Mode (cache + queue) | 14 | Critical (mobile) | 20 hours | No (Step 14) |
| Accessibility Audit | All | Critical | 8 hours | No (ongoing) |
| Earmark Reordering | 8 | Nice-to-have | 3 hours | No |
| Duplicate Transaction | 5 | Nice-to-have | 2 hours | No |
| Skip Scheduled Transaction Occurrence | 9 | Nice-to-have | 2 hours | No |
| Batch Pay Scheduled Transactions | 9 | Nice-to-have | 5 hours | No |
| Amount Range Filter | 6 | Nice-to-have | 4 hours | No |
| Search in Notes | 6 | Nice-to-have | 3 hours | No |
| Earmark Transfers | 8 | Nice-to-have | 5 hours | No |
| Filter Presets | 6 | Nice-to-have | 8 hours | No |
| Keyboard Shortcuts (macOS) | All | Important | 3 hours | No |
| Settings/Preferences | All | Nice-to-have | 4 hours | No |
| Global Search | All | Nice-to-have | 12 hours | No |
| Recent Items | All | Nice-to-have | 4 hours | No |
| Dark Mode Audit | All | Important | 4 hours | No |

**Total Critical Gaps:** 41 hours (Account CRUD, Scheduled Transaction UI/Pay, Offline Mode)
**Total Important Gaps:** 48 hours (Autocomplete, Filters, Earmark UI, Bulk Ops, Export, etc.)
**Total Nice-to-have Gaps:** 52 hours (Polish, convenience features)

**Grand Total:** 141 hours to reach 100% feature parity with moolah web app for Steps 1-9.

---

## Implementation Recommendations

### Phase 1: Critical Gaps (Blocking MVP)
**Priority:** Must be completed before shipping to users.

1. **Account Management (Step 13):**
   - Create/Edit/Delete accounts
   - Opening balance handling
   - Account reordering
   - **Estimate:** 14 hours

2. **Scheduled Transactions (Step 9):**
   - Recurrence UI in TransactionFormView
   - Complete pay action (advance/delete)
   - **Estimate:** 7 hours

3. **Offline Mode (Step 14):**
   - SwiftData cache
   - Write queue
   - Conflict resolution
   - **Estimate:** 20 hours

**Phase 1 Total:** 41 hours

---

### Phase 2: Important Gaps (UX Polish)
**Priority:** Should be completed before initial release.

1. **Transaction Enhancements:**
   - Payee autocomplete
   - Transaction type filter
   - Duplicate action
   - **Estimate:** 7 hours

2. **Earmark Enhancements:**
   - Budget allocation UI
   - Hidden earmarks toggle
   - Earmark reordering
   - **Estimate:** 10 hours

3. **Filtering & Search:**
   - Active filter badge
   - Amount range filter
   - **Estimate:** 5 hours

4. **Bulk Operations:**
   - Multi-select mode
   - Bulk delete/categorize
   - **Estimate:** 8 hours

5. **Account Visibility:**
   - Hidden accounts toggle
   - **Estimate:** 2 hours

6. **Data Export:**
   - CSV/JSON export
   - **Estimate:** 6 hours

7. **Keyboard Shortcuts (macOS):**
   - Complete shortcut coverage
   - **Estimate:** 3 hours

8. **Accessibility Audit:**
   - VoiceOver labels
   - Keyboard navigation
   - Color contrast
   - **Estimate:** 8 hours

9. **Dark Mode Audit:**
   - Test all views
   - Fix hardcoded colors
   - **Estimate:** 4 hours

**Phase 2 Total:** 53 hours

---

### Phase 3: Nice-to-Have (Post-Release)
**Priority:** Can be deferred to updates after initial release.

1. **Advanced Scheduled Transactions:**
   - Skip occurrence
   - Batch pay
   - End date
   - **Estimate:** 15 hours

2. **Advanced Filtering:**
   - Search in notes
   - Exclude categories
   - Filter presets
   - **Estimate:** 14 hours

3. **Earmark Advanced Features:**
   - Earmark transfers
   - Automatic allocation rules
   - **Estimate:** 25 hours

4. **Convenience Features:**
   - Settings screen
   - Global search
   - Recent items
   - Undo/redo
   - **Estimate:** 30 hours

5. **Future Major Features:**
   - Split transactions
   - Attachments/receipts
   - Account colors/icons
   - Multi-currency support
   - **Estimate:** 66+ hours

**Phase 3 Total:** 150+ hours

---

## Testing Checklist

Before marking Steps 1-9 as complete, verify:

- [ ] **Step 1:** All tests pass on iOS Simulator and macOS
- [ ] **Step 2:** Sign in/sign out cycle works; user profile displays correctly
- [ ] **Step 3:** Accounts load and display correct balances; hidden accounts toggle works
- [ ] **Step 4:** Transaction lists paginate correctly; running balances are accurate
- [ ] **Step 5:** Full transaction CRUD cycle works; payee autocomplete functions; recurrence UI complete
- [ ] **Step 6:** All filter combinations work; active filter badge shows; clear all resets
- [ ] **Step 7:** Category tree renders correctly; rename/delete/merge operations work
- [ ] **Step 8:** Earmark overview displays saved/spent/balance; budget UI functional; reordering works
- [ ] **Step 9:** Scheduled transactions display in Upcoming view; pay action advances date; recurrence UI complete
- [ ] **Accessibility:** All views pass VoiceOver test; keyboard navigation works (macOS)
- [ ] **Dark Mode:** All views tested in dark mode; no hardcoded colors
- [ ] **Account Management:** Create/edit/delete/reorder accounts functional

---

## Conclusion

Steps 1-9 have achieved a strong foundation with ~75% feature parity. The remaining gaps fall into three categories:

1. **Critical (41 hours):** Account management and scheduled transaction UI must be completed before shipping.
2. **Important (53 hours):** UX polish items that significantly improve user experience.
3. **Nice-to-have (150+ hours):** Advanced features and convenience enhancements for post-release updates.

**Recommendation:** Complete Phase 1 (Critical) and Phase 2 (Important) before considering Steps 1-9 "done". Defer Phase 3 to post-Step 14 or future releases.

**Next Steps:**
1. Implement account CRUD (Step 13 work pulled forward)
2. Complete scheduled transaction UI (Step 9 finish)
3. Proceed to Step 10 (Analysis Dashboard)
4. Return to polish gaps in Step 14 (Platform Polish & Feature Parity)

---

**End of Gap Analysis**
