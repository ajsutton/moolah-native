# Concurrency Fixes Plan

**Created:** 2026-04-09
**Based on:** Full codebase review against `CONCURRENCY_GUIDE.md`
**Overall assessment:** Codebase is in excellent shape. 0 critical issues, 5 important, 2 minor.

---

## Fix 1: Move `saveTask` from View to Store (Important)

**File:** `Features/Transactions/Views/TransactionDetailView.swift:26`
**Rule:** Anti-patterns — "Storing `Task` in a view `@State`; view identity changes can orphan tasks"

**Problem:** `@State private var saveTask: Task<Void, Never>?` manages debounced auto-save in the view. If SwiftUI recreates the view identity (e.g., user rapidly switches transactions), the orphaned task could fire a stale save.

**Fix:**
1. Add a `debouncedSave(transaction:)` method to `TransactionStore` that owns the `saveTask` property (mirroring the existing `suggestionTask` pattern).
2. The view calls `store.debouncedSave(transaction)` instead of managing the task itself.
3. The store cancels the previous task, sleeps, checks `Task.isCancelled`, then performs the save.

**Reference pattern:** `TransactionStore.fetchPayeeSuggestions` (line ~192) already does exactly this.

**Test:** Add a test in `TransactionStoreTests` that verifies rapid calls to `debouncedSave` only result in one server update (the last one).

---

## Fix 2: Remove redundant `MainActor.run` in TransactionListView (Important)

**File:** `Features/Transactions/Views/TransactionListView.swift:90-99`
**Rule:** Task hygiene — `Task { }` in a view inherits `@MainActor` isolation; wrapping code in `await MainActor.run { }` is redundant.

**Current code:**
```swift
Task {
    if let created = await transactionStore.create(newTransaction) {
        await MainActor.run {
            if selectedTransaction?.id == newTransaction.id {
                selectedTransaction = created
            }
        }
    }
}
```

**Fix:** Remove the `await MainActor.run { }` wrapper:
```swift
Task {
    if let created = await transactionStore.create(newTransaction) {
        if selectedTransaction?.id == newTransaction.id {
            selectedTransaction = created
        }
    }
}
```

---

## Fix 3: Remove redundant `MainActor.run` in TransactionDetailView (Important)

**File:** `Features/Transactions/Views/TransactionDetailView.swift:418`
**Rule:** Same as Fix 2.

**Fix:** Replace `await MainActor.run { saveIfValid() }` with just `saveIfValid()` inside the `Task { }`.

---

## Fix 4: Add explicit `Sendable` to `RemoteAnalysisRepository` (Important)

**File:** `Backends/Remote/Repositories/RemoteAnalysisRepository.swift:3`
**Rule:** Section 2 — "Remote Implementations: `Sendable` Final Classes"

**Problem:** Every other remote repository explicitly declares `Sendable` (`RemoteAccountRepository`, `RemoteTransactionRepository`, `RemoteCategoryRepository`, `RemoteEarmarkRepository`, `RemoteInvestmentRepository`). This one gets it implicitly through the protocol but should be explicit for consistency.

**Fix:**
```swift
// Before
final class RemoteAnalysisRepository: AnalysisRepository {

// After
final class RemoteAnalysisRepository: AnalysisRepository, Sendable {
```

---

## Fix 5: Add explicit `Sendable` to `InMemoryAnalysisRepository` (Important)

**File:** `Backends/InMemory/InMemoryAnalysisRepository.swift:3`
**Rule:** Section 2 — All other InMemory repositories are `actor` types. This one is a plain `final class`.

**Problem:** It only holds `let` references to actor types (no mutable state), so it's safe but inconsistent with the pattern. Since it has no mutable state of its own, making it an `actor` would add unnecessary overhead.

**Fix:** Add explicit `Sendable`:
```swift
// Before
final class InMemoryAnalysisRepository: AnalysisRepository {

// After
final class InMemoryAnalysisRepository: AnalysisRepository, Sendable {
```

**Note:** If mutable state is ever added to this class, it should be converted to an `actor` to match the other InMemory repositories.

---

## Fix 6: Add error logging to reorder operations (Minor)

**Files:**
- `Features/Earmarks/EarmarkStore.swift:100` — `_ = try? await repository.update(visible[index])`
- `Features/Navigation/SidebarView.swift:210-233` — `_ = try? await accountStore.update(updated)`

**Rule:** Anti-patterns — "Fire-and-forget `Task { }` in stores without error handling"

**Problem:** Reorder operations silently swallow errors with `try?`. If an update fails, local state diverges from server state with no indication to the user.

**Fix:** Log errors and optionally surface them. At minimum:
```swift
// Before
_ = try? await repository.update(visible[index])

// After
do {
    _ = try await repository.update(visible[index])
} catch {
    logger.error("Failed to persist reorder for \(visible[index].id): \(error)")
}
```

For the SidebarView reorder, the logic should ideally be moved into the store (per the thin-views principle) where it can set an error state. This is a minor refactor.

---

## Implementation Order

These fixes are independent and can be done in any order. Recommended priority:

1. **Fix 4 + Fix 5** — One-line changes, zero risk, immediate consistency improvement
2. **Fix 2 + Fix 3** — Remove dead code, zero risk
3. **Fix 6** — Add logging, low risk
4. **Fix 1** — Requires store refactor + new test, medium effort

---

## Positive Findings (No Action Needed)

The review confirmed these patterns are correctly implemented:

- All 7 stores use `@MainActor @Observable`
- All domain models are `Sendable` value types
- All repository protocols conform to `Sendable`
- No GCD, `Task.detached`, Combine, or callbacks in production code
- Debouncing in `TransactionStore.fetchPayeeSuggestions` follows the guide exactly
- Views consistently use `.task` for data loading (not `onAppear` + `Task`)
- `Task { }` in button actions are 1-3 lines dispatching to stores
- Pagination guards against concurrent loads and rolls back on failure
- Optimistic updates with rollback in AccountStore, TransactionStore, EarmarkStore
- `async let` for parallel fetching in AnalysisStore and InvestmentStore
- All network requests route through `APIClient`
- No `.id()` on ForEach children
