# Scheduled Transactions — Gap Analysis

**Date:** 2026-04-08

## Executive Summary

Scheduled (recurring) transaction functionality is **partially implemented** in moolah-native. The domain models, filtering, and basic viewing are complete, but critical UI for creating/editing scheduled transactions and several backend behaviors are missing.

This document details the complete scheduled transaction feature set available in moolah-server and the moolah web app, identifies what's already implemented in moolah-native, and specifies what remains to be built.

---

## Complete Feature Set (moolah-server + moolah web app)

### 1. Data Model

**Database Schema** (`moolah-server/db/patches/20170723133524_addSchedulingToTransaction.js`):
- `recur_period` VARCHAR(10): `'ONCE'`, `'DAY'`, `'WEEK'`, `'MONTH'`, `'YEAR'`
- `recur_every` INT: multiplier (e.g., 2 for "every 2 weeks")

**Semantics:**
- `recurPeriod === 'ONCE'` → one-time future transaction (not recurring)
- `recurPeriod === null` → normal completed transaction (not scheduled)
- `recurPeriod !== null && recurPeriod !== 'ONCE'` → recurring scheduled transaction

### 2. Server API

**Filtering:**
- `GET /transactions?scheduled=true` returns all scheduled transactions (where `recurPeriod IS NOT NULL`)
- `GET /transactions?scheduled=false` returns only completed transactions (where `recurPeriod IS NULL`)

**CRUD:**
- `POST /transactions` accepts `recurPeriod` and `recurEvery` (optional, nullable)
- `PUT /transactions/:id` accepts `recurPeriod` and `recurEvery` updates
- No special "pay" endpoint — the web app orchestrates create + update/delete client-side

**Validation** (`moolah-server/src/handlers/types.js`):
- `recurEvery`: integer, min 1
- `recurPeriod`: enum `'ONCE' | 'DAY' | 'WEEK' | 'MONTH' | 'YEAR'`

### 3. Next Due Date Calculation

**Location:** `moolah-server/src/model/transaction/nextDueDate.js`

**Logic:**
- Given a scheduled transaction with `date`, `recurPeriod`, `recurEvery`:
  - `DAY` → `addDays(date, recurEvery)`
  - `WEEK` → `addWeeks(date, recurEvery)`
  - `MONTH` → `addMonths(date, recurEvery)`
  - `YEAR` → `addYears(date, recurEvery)`

**Used by:**
- Web app when paying a recurring transaction (updates the scheduled transaction's `date` to the next due date)

### 4. Pay Action (Web App)

**Location:** `moolah/src/stores/transactions/transactionStore.js` → `actions.payTransaction`

**Behavior:**
1. Create a **non-scheduled** copy of the scheduled transaction:
   - New UUID
   - Today's date (or user-selected date)
   - `recurPeriod: null`, `recurEvery: null`
   - All other fields copied (amount, payee, category, earmark, etc.)
2. If `recurPeriod === 'ONCE'`:
   - Delete the original scheduled transaction
3. Else (recurring):
   - Calculate next due date using `nextDueDate(transaction)`
   - Update the original scheduled transaction's `date` to next due date
4. Execute both operations (create + delete/update) in parallel

**Result:**
- One-time scheduled transactions disappear after being paid
- Recurring transactions advance to the next occurrence

### 5. Forecasting Future Transactions

**Location:** `moolah-server/src/model/transaction/forecastScheduledTransactions.js`

**Purpose:** Generate hypothetical future transaction instances for net-worth forecasting

**Functions:**
- `extrapolateScheduledTransaction(transaction, forecastUntil)`: generates all instances of a single scheduled transaction up to `forecastUntil` date
- `extrapolateScheduledTransactions(scheduledTransactions, forecastUntil)`: flattens and sorts all instances
- `forecastBalances(scheduledTransactions, currentNetWorth, currentEarmarks, until)`: projects daily balances forward by applying scheduled transactions

**Usage:**
- Analysis endpoint (`GET /analysis/daily-balances?forecastUntil=YYYY-MM-DD`) optionally includes `scheduledBalances` array
- Net-worth graph shows actual balances (solid line) + forecasted balances from scheduled transactions (dotted line or shaded area)

### 6. Web UI Components

#### a. Upcoming Transactions View (`UpcomingTransactions.vue`)

**Route:** `/upcoming/`

**Features:**
- Fetches `transactions?scheduled=true`
- Splits into two sections:
  - **Overdue:** `transaction.date < today` (highlighted in red)
  - **Upcoming:** `transaction.date >= today`
- Each row shows:
  - Payee
  - Date
  - Recurrence description (e.g., "Every month", "Every 2 weeks")
  - Category/earmark badges
  - Amount
  - **Pay button** (calls `payTransaction` action)

**Props:**
- `shortTerm: Boolean` — if true, filters to transactions within 14 days (used in Analysis dashboard widget)

#### b. Recurrence Controls (`RecurranceControls.vue`)

**Features:**
- **Switch:** "Repeat" (on/off)
  - Off → `recurPeriod: 'ONCE'`, `recurEvery: null`
  - On → shows period/frequency fields
- **Every field:** number input (min 1)
- **Period dropdown:** Days, Weeks, Months, Years
- Dynamically updates the transaction in the store

**Used in:**
- `EditTransaction.vue` — only shown when `scheduled === true` (editing a scheduled transaction)

#### c. Transaction Form (`EditTransaction.vue`)

**Scheduled vs. Non-Scheduled:**
- Form detects if `transaction.scheduled === true` (passed as prop from parent)
- If scheduled:
  - Shows `<recurrence>` component
  - Shows "Account" picker at bottom (scheduled transactions may have `accountId: undefined` initially)
  - Shows **"Pay"** button (in addition to "Delete")
- Else:
  - Hides recurrence controls
  - Normal transaction form

#### d. Analysis Dashboard Widget

**Location:** `Analysis.vue`

**Display:**
- Shows `<upcoming-transactions :short-term="true">` in the left column
- Only shows transactions with `date` within 14 days
- Serves as a "what's coming up soon" widget

### 7. Navigation

**Main Nav Sidebar:**
- **"Upcoming transactions"** link (`/upcoming/`) with clock icon
- Located between "Categories" and "All transactions"

---

## What's Implemented in moolah-native

### ✅ Domain Layer

**File:** `Domain/Models/Transaction.swift`

- `recurPeriod: String?` field
- `recurEvery: Int?` field
- `isScheduled: Bool` computed property (`recurPeriod != nil`)

**File:** `Domain/Models/Transaction.swift` → `TransactionFilter`

- `scheduled: Bool?` filter field

### ✅ Backend Layer

**InMemoryBackend:**
- Filters transactions by `scheduled` correctly
- Stores and retrieves `recurPeriod` and `recurEvery`

**RemoteBackend:**
- `TransactionDTO` includes `recurPeriod` and `recurEvery`
- Query parameter construction for `scheduled=true`

### ✅ UI — Upcoming View

**File:** `Features/Transactions/Views/UpcomingView.swift`

- Fetches scheduled transactions (`TransactionFilter(scheduled: true)`)
- Splits into "Overdue" and "Upcoming" sections
- Displays recurrence description (e.g., "Every month")
- Pay button on each row
- Empty state for no scheduled transactions

**Pay Action (current implementation):**
- Creates a non-scheduled copy with today's date
- **Does NOT update or delete the original scheduled transaction** (gap!)

### ✅ Tests

**File:** `MoolahTests/Domain/ScheduledTransactionTests.swift`

- `isScheduled` property
- Creating a paid copy (structure only)
- Filtering scheduled transactions
- Overdue classification
- Recurrence period values

---

## What's MISSING in moolah-native

### ❌ 1. Recurrence UI in Transaction Form

**Gap:** No UI to set `recurPeriod` and `recurEvery` when creating or editing a transaction.

**Required:**
- Add a "Repeat" toggle to `TransactionFormView`
- When enabled:
  - Show "Every" number field (min 1)
  - Show "Period" picker: Day, Week, Month, Year
- When disabled or creating a non-scheduled transaction:
  - Set `recurPeriod: nil`, `recurEvery: nil`
- Preserve existing recurrence settings when editing (currently: lines 234–235 copy existing values but user cannot change them)

**Acceptance Criteria:**
- User can create a new scheduled transaction (e.g., "Rent, every month")
- User can edit an existing scheduled transaction's recurrence (change "every month" to "every 2 weeks")
- User can convert a scheduled transaction to one-time by toggling repeat off
- Form validates that if repeat is on, both period and every must be set

### ❌ 2. Next Due Date Calculation

**Gap:** `UpcomingView.payTransaction(_:)` creates a paid transaction but does not update the scheduled transaction's date to the next occurrence.

**Required:**
- Implement `nextDueDate(transaction:) -> Date` utility (mirror `moolah-server/src/model/transaction/nextDueDate.js`):
  - Use `Calendar.current` and `DateComponents`
  - `DAY` → `calendar.date(byAdding: .day, value: recurEvery, to: date)`
  - `WEEK` → `calendar.date(byAdding: .weekOfYear, value: recurEvery, to: date)`
  - `MONTH` → `calendar.date(byAdding: .month, value: recurEvery, to: date)`
  - `YEAR` → `calendar.date(byAdding: .year, value: recurEvery, to: date)`

**Location:** Create `Domain/Models/Recurrence.swift` or add to `Transaction.swift` as an extension.

### ❌ 3. One-Time (ONCE) Scheduled Transactions

**Gap:** The pay action does not handle `recurPeriod === 'ONCE'` (one-time future transactions).

**Required:**
- When paying a scheduled transaction:
  - If `recurPeriod == nil` → error (shouldn't happen)
  - If `recurPeriod == "ONCE"`:
    - Create paid transaction
    - **Delete** the original scheduled transaction
  - Else (DAY, WEEK, MONTH, YEAR):
    - Create paid transaction
    - Calculate next due date
    - **Update** the original scheduled transaction's `date` to next due date

**Implementation Note:**
- `TransactionStore.payTransaction(_:)` should orchestrate:
  1. `await transactionStore.create(paidTransaction)`
  2. If `ONCE`: `await transactionStore.delete(id: scheduledTransaction.id)`
  3. Else: `await transactionStore.update(updated: scheduledTransaction.copy(date: nextDueDate))`

### ❌ 4. RecurPeriod Enum

**Gap:** Recurrence period is currently stored as `String?`, allowing invalid values.

**Required:**
- Define `RecurPeriod` enum:
  ```swift
  enum RecurPeriod: String, Codable, Sendable, CaseIterable {
    case once = "ONCE"
    case day = "DAY"
    case week = "WEEK"
    case month = "MONTH"
    case year = "YEAR"
  }
  ```
- Update `Transaction`:
  - `var recurPeriod: RecurPeriod?`
  - `var isScheduled: Bool { recurPeriod != nil }`
- Update DTOs and tests accordingly

### ❌ 5. Forecasting Scheduled Transactions (Analysis)

**Gap:** The Analysis dashboard's net-worth graph does not show forecasted future balances based on scheduled transactions.

**Required:**

#### a. Domain Model

Create `ForecastedBalance` (or similar):
```swift
struct DailyBalance: Sendable {
  let date: Date
  let balance: MonetaryAmount
  let isForecast: Bool
}
```

#### b. Analysis Repository

Extend `AnalysisRepository`:
```swift
protocol AnalysisRepository {
  func fetchDailyBalances(
    dateRange: ClosedRange<Date>,
    includeForecast: Bool
  ) async throws -> [DailyBalance]
}
```

#### c. InMemoryBackend

- Fetch all scheduled transactions
- For each date in range:
  - Start with current net worth
  - Extrapolate scheduled transactions up to `dateRange.upperBound`
  - Apply each extrapolated transaction to running balance
  - Mark `isForecast: true` for future dates

#### d. RemoteBackend

- Call `GET /analysis/daily-balances?forecastUntil=YYYY-MM-DD`
- Server response includes `dailyBalances` (actual) and `scheduledBalances` (forecast)
- Map both arrays to `[DailyBalance]` with appropriate `isForecast` flag

#### e. UI

- `NetWorthGraph` (Swift Charts):
  - Actual balances: solid line
  - Forecasted balances: dashed line or shaded area
  - Visual distinction (e.g., color/opacity)

**Priority:** Medium (deferred until Step 10 in NATIVE_APP_PLAN.md — Analysis Dashboard)

### ❌ 6. Short-Term Upcoming Widget on Dashboard

**Gap:** The Analysis view does not show a "next 14 days" upcoming transactions widget.

**Required:**
- Add `UpcomingView(shortTerm: true)` to `AnalysisView`
- Filter scheduled transactions to `date <= today + 14 days`
- Display in a card/section on the dashboard (mirror web app layout)

**Priority:** Low (polish; not core functionality)

### ❌ 7. Pay Action Backend Orchestration

**Gap:** Current `payTransaction` creates a new transaction but does not update/delete the original.

**Required:**
- `TransactionStore.payTransaction(_:)` should:
  1. Validate the transaction is scheduled
  2. Create the paid (non-scheduled) copy
  3. If `recurPeriod == .once`: delete original
  4. Else: update original with next due date
  5. Optimistically update UI, rollback on error

**Location:** `Features/Transactions/Stores/TransactionStore.swift`

**Contract Tests:**
- Add to `MoolahTests/Domain/TransactionRepositoryContractTests.swift`:
  - Pay a one-time scheduled transaction → original is deleted
  - Pay a recurring scheduled transaction → original date advances to next occurrence
  - Pay action failure rolls back UI changes

### ❌ 8. Validation Rules

**Gap:** No validation that recurring transactions have both `recurPeriod` and `recurEvery` set.

**Required:**
- `TransactionFormView` validation:
  - If repeat toggle is on, require both period and frequency
  - `recurEvery` must be ≥ 1
- Domain-level validation (optional but recommended):
  - Add `Transaction.validate() throws` method
  - Throw error if `recurPeriod != nil && recurEvery == nil` or vice versa

**Priority:** High (data integrity)

### ❌ 9. Server-Side Pay Endpoint (Future)

**Gap:** Web app orchestrates pay action client-side (create + update/delete). moolah-native will do the same initially, but a dedicated server endpoint would be cleaner.

**Recommendation (out of scope for native app):**
- Add `POST /transactions/:id/pay` endpoint to moolah-server
- Request body: `{ date: 'YYYY-MM-DD' }` (optional, defaults to today)
- Response: `{ paid: Transaction, updated?: Transaction }` or `{ paid: Transaction, deleted: true }`
- Single atomic operation, simpler client-side logic

**Priority:** Low (server-side enhancement; native app can use current approach)

---

## Implementation Roadmap

### Phase 1: Core Functionality ✅ COMPLETE (2026-04-09)

1. ✅ **Define `RecurPeriod` enum** (replace `String?`)
   - Update `Transaction`, `TransactionDTO`, tests
   - Implemented in `Domain/Models/Transaction.swift`

2. ✅ **Implement `nextDueDate(transaction:)` utility**
   - Add to `Domain/Models/Transaction.swift` extension
   - Write tests for each period type
   - Implemented at Transaction.swift:178

3. ✅ **Add recurrence UI to `TransactionFormView`**
   - Toggle, period picker, frequency field
   - Validation
   - Tests (UI snapshot + unit)
   - Implemented at TransactionFormView.swift:212-254

4. ✅ **Implement full pay action in `TransactionStore`**
   - Create + update/delete orchestration
   - Error handling + rollback
   - Contract tests
   - Implemented at TransactionStore.swift:99-136

5. ✅ **Validation: require both period and frequency when repeat is on**
   - Form-level validation
   - Domain-level `Transaction.validate()`
   - Implemented at TransactionFormView.swift:88-90

**Total Phase 1: COMPLETE**

### Phase 2: Analysis Forecasting (Medium Priority)

6. **Forecast scheduled transactions in `InMemoryAnalysisRepository`**
   - Extrapolation logic
   - Tests
   - Estimated effort: 4 hours

7. **Fetch forecasted balances from `RemoteAnalysisRepository`**
   - Parse server response
   - Map to `DailyBalance` model
   - Tests with fixture JSON
   - Estimated effort: 2 hours

8. **Update `NetWorthGraph` to display forecasted balances**
   - Dashed line or shaded area
   - Legend/tooltip
   - Estimated effort: 3 hours

**Total Phase 2: ~9 hours**

### Phase 3: Polish (Low Priority)

9. **Short-term upcoming widget on Analysis dashboard**
   - Add `UpcomingView(shortTerm: true)` section
   - Estimated effort: 1 hour

10. **Server-side pay endpoint** (optional, server work)
    - Out of scope for native app plan
    - Would simplify client logic but not required

**Total Phase 3: ~1 hour**

---

## Summary

**Current State (Updated 2026-04-09):**
- ✅ Data model complete
- ✅ Filtering and viewing scheduled transactions works
- ✅ **Phase 1 COMPLETE**: Full recurrence UI and pay action implemented
  - ✅ RecurPeriod enum defined
  - ✅ UI to create/edit recurrence in TransactionFormView
  - ✅ Complete pay action with update/delete logic
  - ✅ Next due date calculation
  - ✅ Validation for recurrence fields
- ❌ No forecasting for analysis graphs (Phase 2)

**Estimated Remaining Effort:** ~10 hours for forecasting (Phase 2 + 3)

**Recommended Approach:**
1. ✅ **Phase 1 (core functionality) — COMPLETE**
2. Defer Phase 2 (forecasting) until **Step 10** (Analysis Dashboard)
3. Defer Phase 3 (polish) until **Step 14** (Platform Polish & Feature Parity)

---

## Appendices

### A. Web App File References

| Feature | File Path |
|---------|-----------|
| Upcoming view | `moolah/src/components/transactions/UpcomingTransactions.vue` |
| Recurrence controls | `moolah/src/components/transactions/RecurranceControls.vue` |
| Transaction form | `moolah/src/components/transactions/EditTransaction.vue` |
| Pay action | `moolah/src/stores/transactions/transactionStore.js` |
| Forecasting logic | `moolah-server/src/model/transaction/forecastScheduledTransactions.js` |
| Next due date | `moolah-server/src/model/transaction/nextDueDate.js` |

### B. Native App File References

| Component | File Path |
|-----------|-----------|
| Transaction model | `Moolah/Domain/Models/Transaction.swift` |
| Upcoming view | `Moolah/Features/Transactions/Views/UpcomingView.swift` |
| Transaction form | `Moolah/Features/Transactions/Views/TransactionFormView.swift` |
| Tests | `Moolah/MoolahTests/Domain/ScheduledTransactionTests.swift` |

---

**End of Gap Analysis**
