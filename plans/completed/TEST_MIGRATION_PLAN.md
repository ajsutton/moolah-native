# Migrate Tests from InMemoryBackend to CloudKitBackend with In-Memory SwiftData

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate `InMemoryBackend` and all `InMemory*Repository` implementations entirely. All tests and previews will use `CloudKitBackend` backed by an in-memory SwiftData `ModelContainer` — same production code path, but fast, isolated, and with no CloudKit sync.

**Why:** The InMemory repositories are a second implementation of every repository, duplicating business logic (filtering, sorting, validation, analysis computation). Any bug fix or feature change requires updating two implementations. By testing against the real `CloudKitBackend`, we get higher-fidelity tests and eliminate ~600 lines of duplicate logic.

**Tech Stack:** Swift 6.2, SwiftUI, SwiftData, Testing framework

---

## Risk Assessment

**High risk (front-loaded):**
1. **InMemory repositories may have different behavior from CloudKit repos.** The InMemory repos are plain-Swift arrays; CloudKit repos use SwiftData predicates. Differences in sort order, filter semantics, or validation could cause test failures. Contract tests already cover both, so known differences should be minimal, but edge cases may surface.
2. **Store tests that construct individual InMemory*Repository instances** (e.g., `InMemoryAccountRepository(initialAccounts: [...])`) need a new pattern for seeding data into SwiftData. This is the most mechanical but highest-volume change.
3. **InMemoryAuthProvider and InMemoryServerValidator** are true test doubles (configurable behavior), not repository reimplementations. They must be preserved even after InMemory repositories are deleted.

**Medium risk:**
4. **SwiftUI previews** use InMemoryBackend for sample data. Previews need to work synchronously (no `await`), so the seeding pattern must be synchronous `ModelContext.insert()` calls.
5. **Analysis repository** is the most complex InMemory implementation (~580 lines). The CloudKit implementation computes the same results but via SwiftData queries. Behavioral parity must be verified before migration.

**Low risk:**
6. **Contract tests** become simpler (one implementation instead of two argument lists).
7. **Migration tests** (`MigrationIntegrationTests`) use InMemoryBackend as a data source for export. These need to seed data directly into SwiftData instead.

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `MoolahTests/Support/TestBackend.swift` | **Create** | Factory for in-memory `CloudKitBackend` + data seeding helpers |
| `MoolahTests/Support/TestModelContainer.swift` | Keep | Already exists, used by `TestBackend` |
| `MoolahTests/Features/AccountStoreTests.swift` | Modify | Replace `InMemoryAccountRepository` with `TestBackend` |
| `MoolahTests/Features/TransactionStoreTests.swift` | Modify | Replace `InMemoryTransactionRepository` with `TestBackend` |
| `MoolahTests/Features/EarmarkStoreTests.swift` | Modify | Replace `InMemoryEarmarkRepository` with `TestBackend` |
| `MoolahTests/Features/EarmarkBudgetTests.swift` | Modify | Replace `InMemoryEarmarkRepository` with `TestBackend` |
| `MoolahTests/Features/InvestmentStoreTests.swift` | Modify | Replace `InMemoryInvestmentRepository` with `TestBackend` |
| `MoolahTests/Features/AnalysisStoreTests.swift` | Modify | Replace `InMemoryBackend().analysis` with `TestBackend` |
| `MoolahTests/Features/AuthStoreTests.swift` | Modify | Replace `InMemoryBackend(auth:)` with `TestBackend` (keep `InMemoryAuthProvider`) |
| `MoolahTests/Features/ProfileStoreTests.swift` | Modify | Replace `InMemoryServerValidator` usage (keep `InMemoryServerValidator`) |
| `MoolahTests/Domain/*ContractTests.swift` (7 files) | Modify | Remove InMemory arguments, keep only CloudKit |
| `MoolahTests/Migration/MigrationIntegrationTests.swift` | Modify | Seed via SwiftData instead of InMemoryBackend |
| `MoolahTests/Migration/ServerDataExporterTests.swift` | Modify | Seed via SwiftData instead of InMemoryBackend |
| `Features/*/Views/*.swift` (previews, ~12 files) | Modify | Replace InMemory usage with in-memory CloudKitBackend |
| `Backends/InMemory/*.swift` (9 files) | **Delete** | Final cleanup |
| `project.yml` | Modify | Remove InMemory source group if referenced |

---

## Task 1: Create `TestBackend` Factory

**Files:**
- Create: `MoolahTests/Support/TestBackend.swift`

This is the foundation for all subsequent tasks. It provides a simple factory that returns a `CloudKitBackend` backed by an in-memory `ModelContainer`, plus helpers for seeding data.

- [ ] **Step 1: Create `TestBackend` with `create()` factory**

```swift
import Foundation
import SwiftData
@testable import Moolah

enum TestBackend {
  /// Creates a CloudKitBackend backed by an in-memory ModelContainer.
  /// Each call creates a fresh, isolated container — no cross-test contamination.
  static func create(
    currency: Currency = .defaultTestCurrency,
    profileId: UUID = UUID()
  ) throws -> (backend: CloudKitBackend, container: ModelContainer, profileId: UUID) {
    let container = try TestModelContainer.create()
    let backend = CloudKitBackend(
      modelContainer: container,
      profileId: profileId,
      currency: currency,
      profileLabel: "Test"
    )
    return (backend, container, profileId)
  }
}
```

- [ ] **Step 2: Add data seeding helpers**

Add extension methods for the most common seeding patterns used in tests. These insert `*Record` objects directly into the ModelContext (synchronous, no async needed).

```swift
extension TestBackend {
  /// Seeds accounts into the in-memory store. Returns the accounts as-is (IDs preserved).
  @discardableResult
  static func seed(
    accounts: [Account],
    in container: ModelContainer,
    profileId: UUID
  ) -> [Account] {
    let context = ModelContext(container)
    for account in accounts {
      context.insert(AccountRecord.from(account, profileId: profileId))
    }
    try! context.save()
    return accounts
  }

  /// Seeds transactions into the in-memory store.
  @discardableResult
  static func seed(
    transactions: [Transaction],
    in container: ModelContainer,
    profileId: UUID
  ) -> [Transaction] {
    let context = ModelContext(container)
    for txn in transactions {
      context.insert(TransactionRecord.from(txn, profileId: profileId))
    }
    try! context.save()
    return transactions
  }

  // Similar for earmarks, categories, investment values...
}
```

- [ ] **Step 3: Build and run existing tests to verify TestBackend compiles**

Run: `just build-mac`
Expected: Compiles with no errors. Existing tests still pass (TestBackend is not yet used).

- [ ] **Step 4: Commit**

---

## Task 2: Verify Behavioral Parity — Contract Tests as Safety Net

**Files:**
- Review: All `MoolahTests/Domain/*ContractTests.swift` files (7 files)

Before migrating any store tests, confirm that all contract tests pass for both InMemory and CloudKit implementations. Any failures here indicate behavioral differences that must be resolved first.

- [ ] **Step 1: Run all contract tests and document any failures**

Run: `just test`

If any contract test fails for the CloudKit implementation but passes for InMemory (or vice versa), document the difference. Common areas to watch:

- **Sort order:** InMemory sorts by `(date DESC, id ASC)` for transactions. CloudKit may sort differently for ties.
- **Validation:** InMemory `AccountRepository.delete` does a soft-delete (sets `isHidden = true`). CloudKit may behave differently.
- **Analysis computation:** `InMemoryAnalysisRepository` re-fetches transactions multiple times. `CloudKitAnalysisRepository` uses SwiftData queries. Results should match but rounding or date boundary behavior could differ.
- **Category deletion cascades:** InMemory manually updates transactions and budget items. CloudKit may rely on SwiftData relationships.

- [ ] **Step 2: Fix any behavioral differences in CloudKit repos**

If CloudKit repos have bugs exposed by contract tests, fix them before proceeding. This ensures the migration does not regress behavior.

- [ ] **Step 3: Commit any fixes**

---

## Task 3: Migrate Store Tests — AccountStoreTests

**Files:**
- Modify: `MoolahTests/Features/AccountStoreTests.swift`

This is the first store test migration and establishes the pattern for all subsequent ones. `AccountStoreTests` currently constructs `InMemoryAccountRepository(initialAccounts: [...])` and passes it to `AccountStore(repository:)`.

**New pattern:** Create a `TestBackend`, seed accounts via the container, then extract the repository from the backend.

- [ ] **Step 1: Migrate all tests in AccountStoreTests**

Before (current pattern):
```swift
let repository = InMemoryAccountRepository(initialAccounts: [account])
let store = AccountStore(repository: repository)
```

After:
```swift
let (backend, container, profileId) = try TestBackend.create()
TestBackend.seed(accounts: [account], in: container, profileId: profileId)
let store = AccountStore(repository: backend.accounts)
```

Migrate all 15+ tests in this file.

- [ ] **Step 2: Run tests**

Run: `just test`
Expected: All AccountStoreTests pass.

- [ ] **Step 3: Commit**

---

## Task 4: Migrate Store Tests — TransactionStoreTests

**Files:**
- Modify: `MoolahTests/Features/TransactionStoreTests.swift`

Same pattern as Task 3. `TransactionStoreTests` currently uses `InMemoryTransactionRepository(initialTransactions: [...])`.

- [ ] **Step 1: Migrate all tests**
- [ ] **Step 2: Run tests, fix any issues**
- [ ] **Step 3: Commit**

---

## Task 5: Migrate Store Tests — EarmarkStoreTests and EarmarkBudgetTests

**Files:**
- Modify: `MoolahTests/Features/EarmarkStoreTests.swift`
- Modify: `MoolahTests/Features/EarmarkBudgetTests.swift`

`EarmarkStoreTests` uses `InMemoryEarmarkRepository(initialEarmarks: [...])`. `EarmarkBudgetTests` also calls `repository.setBudget(...)` during setup.

**Important:** Earmarks have `saved`, `spent`, and `balance` fields that are pre-set in test data. With CloudKit, these are computed from transactions. Tests that set `saved: 50000, spent: 10000` directly on the Earmark model may need adjustment — either seed corresponding transactions, or verify that the `EarmarkRecord` stores these values directly.

- [ ] **Step 1: Investigate how CloudKitEarmarkRepository handles saved/spent/balance**

Check whether `EarmarkRecord` stores `saved`, `spent`, `balance` fields directly (so seeding works the same) or computes them from transactions.

- [ ] **Step 2: Migrate EarmarkStoreTests**
- [ ] **Step 3: Migrate EarmarkBudgetTests**
- [ ] **Step 4: Run tests, fix any issues**
- [ ] **Step 5: Commit**

---

## Task 6: Migrate Store Tests — InvestmentStoreTests

**Files:**
- Modify: `MoolahTests/Features/InvestmentStoreTests.swift`

Uses `InMemoryInvestmentRepository(initialValues: [...])` and `repo.setDailyBalances(...)`.

**Important:** `InMemoryInvestmentRepository` has a `setDailyBalances` method for test seeding that is not part of the `InvestmentRepository` protocol. The CloudKit implementation computes daily balances from transactions. Tests that rely on `setDailyBalances` need to either:
- Seed transactions that produce the expected daily balances, or
- Add a separate seeding path via direct SwiftData insertion of `InvestmentValueRecord`.

- [ ] **Step 1: Investigate `fetchDailyBalances` in CloudKitInvestmentRepository**
- [ ] **Step 2: Migrate tests**
- [ ] **Step 3: Run tests, fix any issues**
- [ ] **Step 4: Commit**

---

## Task 7: Migrate Store Tests — AnalysisStoreTests

**Files:**
- Modify: `MoolahTests/Features/AnalysisStoreTests.swift`

Uses `InMemoryBackend().analysis` to create `AnalysisStore`. Most tests in this file test pure computation (`buildCategoriesOverTime`, `extrapolateBalances`, `cumulativeSavings`) and do not actually exercise the repository — they pass data directly to static methods.

Only `AnalysisStoreFilterPersistenceTests` creates an `AnalysisStore` with a real repository, and it only tests UserDefaults persistence (not analysis computation).

- [ ] **Step 1: Migrate AnalysisStoreFilterPersistenceTests to use TestBackend**
- [ ] **Step 2: Verify pure-computation tests are unaffected (no InMemory references)**
- [ ] **Step 3: Run tests**
- [ ] **Step 4: Commit**

---

## Task 8: Migrate Store Tests — AuthStoreTests

**Files:**
- Modify: `MoolahTests/Features/AuthStoreTests.swift`

Uses `InMemoryBackend(auth: InMemoryAuthProvider(...))`. The `InMemoryAuthProvider` is a **true test double** — it has configurable behavior (signed in/out, requires sign-in) that cannot be replicated by `CloudKitAuthProvider`. Similarly, `FailingAuthProvider` is a custom test double.

**Decision: Keep `InMemoryAuthProvider` and `InMemoryServerValidator` as test doubles.** They are not repository reimplementations — they are controllable fakes for auth/validation behavior. Rename them to clarify their role (e.g., `MockAuthProvider`, `MockServerValidator`) or leave as-is and just keep the files.

- [ ] **Step 1: Replace `InMemoryBackend(auth: ...)` with direct store construction**

`AuthStore` takes a `BackendProvider`, not just an `AuthProvider`. Create a minimal `TestBackend` that wraps `InMemoryAuthProvider` with `CloudKitBackend` for the repository parts, or refactor `AuthStore` to accept just an `AuthProvider` if it only uses `backend.auth`.

Check what `AuthStore` actually needs from `BackendProvider`:
- If it only uses `.auth`, refactor to accept `AuthProvider` directly.
- If it needs the full backend, create a `TestBackend` with the desired auth provider.

- [ ] **Step 2: Migrate tests**
- [ ] **Step 3: Run tests**
- [ ] **Step 4: Commit**

---

## Task 9: Migrate Contract Tests

**Files:**
- Modify: `MoolahTests/Domain/TransactionRepositoryContractTests.swift`
- Modify: `MoolahTests/Domain/AccountRepositoryContractTests.swift`
- Modify: `MoolahTests/Domain/CategoryRepositoryContractTests.swift`
- Modify: `MoolahTests/Domain/EarmarkRepositoryContractTests.swift`
- Modify: `MoolahTests/Domain/AnalysisRepositoryContractTests.swift`
- Modify: `MoolahTests/Domain/InvestmentRepositoryContractTests.swift`
- Modify: `MoolahTests/Domain/AuthContractTests.swift`

Contract tests currently parameterize over `[InMemory..., CloudKit...]`. Since both implementations will be the same code path, simplify to just the CloudKit implementation.

- [ ] **Step 1: Remove InMemory arguments from all contract tests**

Before:
```swift
@Test("filters by date range", arguments: [
  InMemoryTransactionRepository(initialTransactions: makeTestTransactions())
    as any TransactionRepository,
  makeCloudKitTransactionRepository(initialTransactions: makeTestTransactions())
    as any TransactionRepository,
])
```

After:
```swift
@Test("filters by date range")
func testFiltersByDateRange() async throws {
  let repository = makeCloudKitTransactionRepository(initialTransactions: makeTestTransactions())
  // ... test body unchanged ...
}
```

- [ ] **Step 2: Remove `makeCloudKit*` helper functions that are now redundant** (or keep them if they simplify setup)
- [ ] **Step 3: Run tests**
- [ ] **Step 4: Commit**

---

## Task 10: Migrate Migration Tests

**Files:**
- Modify: `MoolahTests/Migration/MigrationIntegrationTests.swift`
- Modify: `MoolahTests/Migration/ServerDataExporterTests.swift`

These tests use `InMemoryBackend` to seed data, then export it and import into SwiftData. After migration, seed data directly into a CloudKitBackend via `TestBackend`, then export/import/verify.

- [ ] **Step 1: Migrate MigrationIntegrationTests.makeSeededBackend()**

Replace `InMemoryBackend` seeding with `TestBackend.create()` + repository calls (create accounts, transactions, etc. via `backend.accounts.create(...)`, `backend.transactions.create(...)`, etc.).

- [ ] **Step 2: Migrate ServerDataExporterTests.makeBackendWithData()**

Same pattern.

- [ ] **Step 3: Run tests**
- [ ] **Step 4: Commit**

---

## Task 11: Migrate SwiftUI Previews

**Files (all files with `#Preview` using InMemory types):**
- `Features/Analysis/Views/AnalysisView.swift`
- `Features/Analysis/Views/UpcomingTransactionsCard.swift`
- `Features/Earmarks/Views/EarmarksView.swift`
- `Features/Earmarks/Views/EarmarkDetailView.swift`
- `Features/Transactions/Views/AllTransactionsView.swift`
- `Features/Transactions/Views/UpcomingView.swift`
- `Features/Transactions/Views/TransactionDetailView.swift`
- `Features/Transactions/Views/TransactionListView.swift`
- `Features/Categories/Views/CategoriesView.swift`
- `Features/Categories/Views/CategoryTreeView.swift`
- `Features/Navigation/SidebarView.swift`

**Pattern:** Previews need synchronous setup. Use `ModelContext.insert()` to seed data, then create `CloudKitBackend` from the container.

- [ ] **Step 1: Create a `PreviewBackend` helper in the main target**

```swift
import SwiftData

enum PreviewBackend {
  static func create(currency: Currency = .AUD) -> (CloudKitBackend, ModelContainer, UUID) {
    let schema = Schema([
      ProfileRecord.self, AccountRecord.self, TransactionRecord.self,
      CategoryRecord.self, EarmarkRecord.self, EarmarkBudgetItemRecord.self,
      InvestmentValueRecord.self,
    ])
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: schema, configurations: [config])
    let profileId = UUID()
    let backend = CloudKitBackend(
      modelContainer: container, profileId: profileId,
      currency: currency, profileLabel: "Preview"
    )
    return (backend, container, profileId)
  }
}
```

Note: This must be in the main target (not test target) since previews compile against the app.

- [ ] **Step 2: Migrate previews one file at a time**

For each preview, replace:
```swift
let repository = InMemoryTransactionRepository(initialTransactions: [...])
```

With:
```swift
let (backend, container, profileId) = PreviewBackend.create()
let context = ModelContext(container)
for txn in sampleTransactions {
  context.insert(TransactionRecord.from(txn, profileId: profileId))
}
try! context.save()
```

- [ ] **Step 3: Verify previews render in Xcode**
- [ ] **Step 4: Commit**

---

## Task 12: Rename/Relocate Test Doubles

**Files:**
- Rename: `Backends/InMemory/InMemoryAuthProvider.swift` -> `MoolahTests/Support/MockAuthProvider.swift`
- Rename: `Backends/InMemory/InMemoryServerValidator.swift` -> `MoolahTests/Support/MockServerValidator.swift`

These are true test doubles, not repository implementations. Move them to the test target (or a shared test-support location) and rename for clarity.

**Alternative:** If `InMemoryAuthProvider` is used in previews (check first), it needs to stay in the main target. In that case, move it to a `Support/` or `Testing/` directory instead.

- [ ] **Step 1: Check if InMemoryAuthProvider is used in previews**
- [ ] **Step 2: Move files to appropriate location**
- [ ] **Step 3: Update imports and references**
- [ ] **Step 4: Build and test**
- [ ] **Step 5: Commit**

---

## Task 13: Delete InMemory Backend Files

**Files to delete:**
- `Backends/InMemory/InMemoryBackend.swift`
- `Backends/InMemory/InMemoryAccountRepository.swift`
- `Backends/InMemory/InMemoryTransactionRepository.swift`
- `Backends/InMemory/InMemoryCategoryRepository.swift`
- `Backends/InMemory/InMemoryEarmarkRepository.swift`
- `Backends/InMemory/InMemoryAnalysisRepository.swift`
- `Backends/InMemory/InMemoryInvestmentRepository.swift`
- (InMemoryAuthProvider and InMemoryServerValidator already moved in Task 12)

**Precondition:** `grep -r "InMemoryBackend\|InMemoryAccountRepository\|InMemoryTransactionRepository\|InMemoryCategoryRepository\|InMemoryEarmarkRepository\|InMemoryAnalysisRepository\|InMemoryInvestmentRepository"` returns zero hits in `*.swift` files (excluding plans/docs).

- [ ] **Step 1: Verify no remaining references in Swift source files**

```bash
grep -r "InMemory\(Account\|Transaction\|Category\|Earmark\|Analysis\|Investment\)Repository\|InMemoryBackend" --include="*.swift" .
```

Expected: No hits (other than the files being deleted).

- [ ] **Step 2: Delete the files**

```bash
rm Backends/InMemory/InMemoryBackend.swift
rm Backends/InMemory/InMemoryAccountRepository.swift
rm Backends/InMemory/InMemoryTransactionRepository.swift
rm Backends/InMemory/InMemoryCategoryRepository.swift
rm Backends/InMemory/InMemoryEarmarkRepository.swift
rm Backends/InMemory/InMemoryAnalysisRepository.swift
rm Backends/InMemory/InMemoryInvestmentRepository.swift
rmdir Backends/InMemory/  # Only if empty
```

- [ ] **Step 3: Update `project.yml` if it references the InMemory directory**

Check if `project.yml` has explicit source references to `Backends/InMemory/`. If using glob patterns, the directory removal should be sufficient.

- [ ] **Step 4: Regenerate Xcode project**

Run: `just generate`

- [ ] **Step 5: Build and run full test suite**

Run: `just test`
Expected: All tests pass on both iOS and macOS targets.

- [ ] **Step 6: Commit**

---

## Task 14: Update Documentation

**Files:**
- Modify: `CLAUDE.md` — update references to `InMemoryBackend` in testing instructions
- Modify: `CONCURRENCY_GUIDE.md` — update if it references InMemory types
- Modify: `.claude/agents/concurrency-review.md` — update if it references InMemory types

- [ ] **Step 1: Update CLAUDE.md**

Replace references to `InMemoryBackend` with `TestBackend` / `PreviewBackend` in the testing and backend sections.

- [ ] **Step 2: Update any other docs that reference InMemory types**
- [ ] **Step 3: Commit**

---

## Behavioral Differences to Investigate

These are potential differences between InMemory and CloudKit implementations that could cause test failures. Investigate each during Task 2 (contract test verification) and fix before proceeding.

### Known Areas of Concern

1. **`InMemoryAccountRepository.delete()` does soft-delete** (sets `isHidden = true`) instead of actual deletion. Verify `CloudKitAccountRepository.delete()` matches this behavior.

2. **`InMemoryAnalysisRepository` references `InMemoryAnalysisRepository.applyBestFit`** — this static method is used by both InMemory and CloudKit analysis repos. After deleting InMemory, ensure CloudKit repo has its own copy or this is moved to a shared location.

3. **`InMemoryCategoryRepository.delete()` cascades** to transactions and budget items by calling `transactionRepository.replaceCategoryId()` and `earmarkRepository.replaceCategoryInBudgets()`. Verify CloudKit does the same cascade.

4. **`InMemoryInvestmentRepository.fetchDailyBalances()`** returns seeded test data. `CloudKitInvestmentRepository.fetchDailyBalances()` likely computes from real data. Tests using `setDailyBalances()` need a different seeding approach.

5. **Transaction sort stability:** InMemory sorts by `(date DESC, id.uuidString ASC)`. CloudKit SwiftData sorts may not have the same tie-breaking behavior. Tests should not depend on tie-breaking order.

6. **`InMemoryAuthProvider`** — This is NOT a behavioral difference; it's a true test double that must be preserved. Same for `InMemoryServerValidator`.
