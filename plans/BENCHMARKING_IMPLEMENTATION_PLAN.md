# Benchmarking & Performance Instrumentation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Status:** Implemented. All 7 tasks complete — Signposts enum, benchmark target, transaction fetch / balance / sync batch / conversion / sync download / sync upload / analysis benchmarks all operational. Guide written at `guides/BENCHMARKING_GUIDE.md`.

**Goal:** Add performance benchmarks and os_signpost instrumentation to measure and profile data operations at realistic scale (~18k transactions).

**Architecture:** XCTest performance tests in a separate macOS-only target (`MoolahBenchmarks_macOS`) using in-memory SwiftData via `TestBackend`. Signposts added inline to repository and sync engine code using a shared `Signposts` enum.

**Tech Stack:** XCTest `measure(metrics:options:)`, `os_signpost`, SwiftData, existing `TestBackend` infrastructure.

**Key files to read before starting:** `plans/BENCHMARKING_DESIGN.md` (the design spec), `guides/BENCHMARKING_GUIDE.md` (style guide for writing benchmarks), `CLAUDE.md` (build/test instructions).

---

### Task 1: Signposts Enum and Build Infrastructure

Set up the `Signposts` enum, the benchmark test target in `project.yml`, the `just benchmark` command, and verify the empty target builds.

**Files:**
- Create: `Shared/Signposts.swift`
- Create: `MoolahBenchmarks/BenchmarkSmokeTest.swift`
- Create: `scripts/benchmark.sh`
- Modify: `project.yml`
- Modify: `justfile`

- [ ] **Step 1: Create Signposts enum**

Create `Shared/Signposts.swift`:

```swift
import os

enum Signposts {
  static let repository = OSLog(subsystem: "com.moolah.app", category: "Repository")
  static let sync = OSLog(subsystem: "com.moolah.app", category: "Sync")
  static let balance = OSLog(subsystem: "com.moolah.app", category: "Balance")
}
```

- [ ] **Step 2: Create a smoke test for the benchmark target**

Create `MoolahBenchmarks/BenchmarkSmokeTest.swift`:

```swift
import XCTest

@testable import Moolah

final class BenchmarkSmokeTest: XCTestCase {
  func testBenchmarkTargetBuildsAndRuns() {
    // Verify the benchmark target links correctly against Moolah
    let container = try! TestModelContainer.create()
    XCTAssertNotNil(container)
  }
}
```

- [ ] **Step 3: Add benchmark target and scheme to project.yml**

Add after the `MoolahTests_macOS` target block (after line 113):

```yaml
  MoolahBenchmarks_macOS:
    type: bundle.unit-test
    platform: macOS
    sources:
      - path: MoolahBenchmarks
      - path: MoolahTests/Support
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: rocks.moolah.benchmarks
        GENERATE_INFOPLIST_FILE: YES
        CODE_SIGN_IDENTITY: "-"
        CODE_SIGNING_REQUIRED: YES
        CODE_SIGNING_ALLOWED: YES
        ENABLE_HARDENED_RUNTIME: NO
        TEST_HOST: "$(BUILT_PRODUCTS_DIR)/Moolah.app/Contents/MacOS/Moolah"
        BUNDLE_LOADER: "$(TEST_HOST)"
    dependencies:
      - target: Moolah_macOS
```

Add a new scheme after `Moolah-macOS` (after line 138):

```yaml
  Moolah-Benchmarks:
    build:
      targets:
        Moolah_macOS: all
        MoolahBenchmarks_macOS: [test]
    test:
      targets:
        - MoolahBenchmarks_macOS
```

Note: The `sources` includes `MoolahTests/Support` so benchmarks can reuse `TestBackend`, `TestModelContainer`, and `TestCurrency` without duplicating them.

- [ ] **Step 4: Create the benchmark runner script**

Create `scripts/benchmark.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Disable nested sandboxing (same as test.sh)
export SWIFTPM_DISABLE_SANDBOX=1
export SWIFT_BUILD_USE_SANDBOX=0

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

COMMON_ARGS=(
    -IDEPackageSupportDisableManifestSandbox=1
    -IDEPackageSupportDisablePackageSandbox=1
    'OTHER_SWIFT_FLAGS=$(inherited) -disable-sandbox'
)

# Optional filter: class name or class/method
FILTER="${1:-}"

echo "==> Building benchmarks…"
xcodebuild build-for-testing "${COMMON_ARGS[@]}" \
    -derivedDataPath "$REPO_ROOT/.DerivedData-bench" \
    -scheme Moolah-Benchmarks \
    -destination "platform=macOS"

PRODUCTS="$REPO_ROOT/.DerivedData-bench/Build/Products"
APP_BUNDLE="$PRODUCTS/Debug/Moolah.app"
TEST_BUNDLE="$APP_BUNDLE/Contents/PlugIns/MoolahBenchmarks_macOS.xctest"

# Copy debug dylib (same fix as test.sh)
DYLIB="$(find "$APP_BUNDLE/Contents/MacOS" -name "*.debug.dylib" | head -1)"
if [[ -n "$DYLIB" ]]; then
    mkdir -p "$TEST_BUNDLE/Contents/Frameworks"
    cp "$DYLIB" "$TEST_BUNDLE/Contents/Frameworks/"
fi

if [[ -n "$FILTER" ]]; then
    echo "==> Running benchmarks matching: $FILTER"
    xcrun xctest -XCTest "$FILTER" "$TEST_BUNDLE"
else
    echo "==> Running all benchmarks…"
    xcrun xctest "$TEST_BUNDLE"
fi
```

- [ ] **Step 5: Add benchmark target to justfile**

Add after the `test-ios` recipe:

```just
# Run performance benchmarks (macOS only)
benchmark *FILTER: generate
    bash scripts/benchmark.sh {{ FILTER }}
```

- [ ] **Step 6: Generate and build**

Run:
```bash
just generate
```
Expected: Xcode project regenerates without errors.

Run:
```bash
just benchmark
```
Expected: Builds successfully, smoke test passes.

- [ ] **Step 7: Commit**

```bash
git add Shared/Signposts.swift MoolahBenchmarks/BenchmarkSmokeTest.swift \
  scripts/benchmark.sh project.yml justfile
git commit -m "feat: add benchmark target, Signposts enum, and just benchmark command"
```

---

### Task 2: Benchmark Fixtures

Build the `BenchmarkFixtures` helper that seeds realistic datasets at 1x and 2x scale. This is the foundation all benchmarks depend on.

**Files:**
- Create: `MoolahBenchmarks/Support/BenchmarkFixtures.swift`

- [ ] **Step 1: Create BenchmarkFixtures**

Create `MoolahBenchmarks/Support/BenchmarkFixtures.swift`:

```swift
import Foundation
import SwiftData

@testable import Moolah

/// Generates realistic benchmark datasets matching the live iCloud profile distribution.
///
/// Real data profile (1x):
/// - 18,662 transactions across 31 accounts (top 3 hold ~85%)
/// - 158 categories, 21 earmarks, 2,711 investment values
/// - Only ~0.2% scheduled transactions
///
/// 2x target doubles all counts.
enum BenchmarkFixtures {

  // MARK: - Well-Known IDs

  /// The 3 "heavy" accounts that hold ~85% of transactions.
  static let heavyAccountIds: [UUID] = [
    UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
    UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
    UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
  ]

  /// The primary heavy account (~38% of transactions at 1x).
  static let heavyAccountId = heavyAccountIds[0]

  // MARK: - Scale Configurations

  struct Scale {
    let transactionCount: Int
    let accountCount: Int
    let categoryCount: Int
    let earmarkCount: Int
    let investmentValueCount: Int

    /// Distribution of transactions across the heavy accounts.
    /// Remaining transactions are spread across other accounts.
    let heavyAccountShares: [Double]  // [0.38, 0.32, 0.16] = 86%

    static let x1 = Scale(
      transactionCount: 18_662,
      accountCount: 31,
      categoryCount: 158,
      earmarkCount: 21,
      investmentValueCount: 2_711,
      heavyAccountShares: [0.38, 0.32, 0.16]
    )

    static let x2 = Scale(
      transactionCount: 37_000,
      accountCount: 60,
      categoryCount: 320,
      earmarkCount: 42,
      investmentValueCount: 5_400,
      heavyAccountShares: [0.38, 0.32, 0.16]
    )
  }

  // MARK: - Seeding

  /// Seeds a complete dataset at the given scale.
  /// Returns the ModelContainer for use in benchmarks.
  @MainActor
  static func seed(scale: Scale, in container: ModelContainer) {
    let context = container.mainContext
    let currency = Currency.defaultTestCurrency

    // 1. Accounts
    let accountIds = seedAccounts(
      count: scale.accountCount, currency: currency, context: context)

    // 2. Categories
    let categoryIds = seedCategories(count: scale.categoryCount, context: context)

    // 3. Earmarks
    let earmarkIds = seedEarmarks(
      count: scale.earmarkCount, currency: currency, context: context)

    // 4. Transactions (with realistic distribution)
    seedTransactions(
      count: scale.transactionCount,
      accountIds: accountIds,
      categoryIds: categoryIds,
      earmarkIds: earmarkIds,
      heavyAccountShares: scale.heavyAccountShares,
      currency: currency,
      context: context
    )

    // 5. Investment values (spread across investment-type accounts)
    let investmentAccountIds = Array(accountIds.suffix(6))  // last 6 are "investment" type
    seedInvestmentValues(
      count: scale.investmentValueCount,
      accountIds: investmentAccountIds,
      currency: currency,
      context: context
    )

    try! context.save()
  }

  // MARK: - Per-Type Seeding

  @MainActor
  private static func seedAccounts(
    count: Int, currency: Currency, context: ModelContext
  ) -> [UUID] {
    var ids: [UUID] = []

    // First 3 are the heavy accounts with well-known IDs
    for i in 0..<min(count, 3) {
      let id = heavyAccountIds[i]
      let record = AccountRecord(
        id: id, name: "Heavy Account \(i)", type: AccountType.bank.rawValue,
        position: i, isHidden: false, currencyCode: currency.code, cachedBalance: nil)
      context.insert(record)
      ids.append(id)
    }

    // Remaining accounts
    for i in 3..<count {
      let id = UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", i))")!
      let type: String
      if i >= count - 6 {
        type = AccountType.investment.rawValue
      } else if i >= count - 9 {
        type = AccountType.creditCard.rawValue
      } else {
        type = AccountType.bank.rawValue
      }
      let record = AccountRecord(
        id: id, name: "Account \(i)", type: type,
        position: i, isHidden: false, currencyCode: currency.code, cachedBalance: nil)
      context.insert(record)
      ids.append(id)
    }

    return ids
  }

  @MainActor
  private static func seedCategories(count: Int, context: ModelContext) -> [UUID] {
    var ids: [UUID] = []
    for i in 0..<count {
      let id = UUID(uuidString: "10000000-0000-0000-0000-\(String(format: "%012d", i))")!
      let record = CategoryRecord(id: id, name: "Category \(i)", parentId: nil)
      context.insert(record)
      ids.append(id)
    }
    return ids
  }

  @MainActor
  private static func seedEarmarks(
    count: Int, currency: Currency, context: ModelContext
  ) -> [UUID] {
    var ids: [UUID] = []
    for i in 0..<count {
      let id = UUID(uuidString: "20000000-0000-0000-0000-\(String(format: "%012d", i))")!
      let record = EarmarkRecord(
        id: id, name: "Earmark \(i)", position: i, isHidden: false,
        savingsTarget: 100_00, currencyCode: currency.code,
        savingsStartDate: nil, savingsEndDate: nil)
      context.insert(record)
      ids.append(id)
    }
    return ids
  }

  @MainActor
  private static func seedTransactions(
    count: Int,
    accountIds: [UUID],
    categoryIds: [UUID],
    earmarkIds: [UUID],
    heavyAccountShares: [Double],
    currency: Currency,
    context: ModelContext
  ) {
    let payees = [
      "Woolworths", "Coles", "Aldi", "Amazon", "Netflix", "Spotify",
      "Shell", "BP", "Uber", "Coffee Shop", "Restaurant", "Pharmacy",
      "Hardware Store", "Insurance Co", "Electric Company", "Water Utility",
    ]

    // Assign each transaction to an account using the heavy distribution
    let heavyCount = heavyAccountIds.count
    let otherAccountIds = Array(accountIds.dropFirst(heavyCount))
    let scheduledCount = max(1, count / 500)  // ~0.2% scheduled

    // Base date: 5 years ago. One transaction roughly every few hours.
    let calendar = Calendar.current
    let startDate = calendar.date(byAdding: .year, value: -5, to: Date())!

    for i in 0..<count {
      let id = UUID(uuidString: "30000000-0000-\(String(format: "%04x", i / 65536))-\(String(format: "%04x", i % 65536))-000000000000")!

      // Determine account using the heavy distribution
      let fraction = Double(i) / Double(count)
      let finalAccountId: UUID = {
        var runningShare = 0.0
        for (idx, share) in heavyAccountShares.enumerated() where idx < heavyCount {
          runningShare += share
          if fraction < runningShare { return heavyAccountIds[idx] }
        }
        // Remaining ~14% spread across other accounts
        if otherAccountIds.isEmpty { return heavyAccountIds[0] }
        return otherAccountIds[i % otherAccountIds.count]
      }()

      // Determine type
      let isScheduled = i < scheduledCount
      let typeRoll = i % 10
      let type: String
      let amount: Int
      if typeRoll < 6 {
        type = TransactionType.expense.rawValue
        amount = -((i % 200 + 1) * 100)  // -$1 to -$200
      } else if typeRoll < 9 {
        type = TransactionType.income.rawValue
        amount = (i % 500 + 1) * 100  // $1 to $500
      } else {
        type = TransactionType.transfer.rawValue
        amount = -((i % 100 + 1) * 100)
      }

      // Spread dates across 5 years
      let hoursOffset = (i * 5 * 365 * 24) / count
      let date = calendar.date(byAdding: .hour, value: hoursOffset, to: startDate)!

      let record = TransactionRecord(
        id: id,
        type: type,
        date: date,
        accountId: finalAccountId,
        toAccountId: type == TransactionType.transfer.rawValue
          ? accountIds[(i + 1) % accountIds.count] : nil,
        amount: amount,
        currencyCode: currency.code,
        payee: payees[i % payees.count],
        notes: i % 5 == 0 ? "Note for transaction \(i)" : nil,
        categoryId: categoryIds[i % categoryIds.count],
        earmarkId: i % 20 == 0 ? earmarkIds[i % earmarkIds.count] : nil,
        recurPeriod: isScheduled ? RecurPeriod.month.rawValue : nil,
        recurEvery: isScheduled ? 1 : nil
      )
      context.insert(record)
    }
  }

  @MainActor
  private static func seedInvestmentValues(
    count: Int, accountIds: [UUID], currency: Currency, context: ModelContext
  ) {
    guard !accountIds.isEmpty else { return }
    let calendar = Calendar.current
    let startDate = calendar.date(byAdding: .year, value: -5, to: Date())!

    for i in 0..<count {
      let id = UUID(uuidString: "40000000-0000-0000-0000-\(String(format: "%012d", i))")!
      let accountId = accountIds[i % accountIds.count]
      let daysOffset = (i * 5 * 365) / max(1, count / accountIds.count)
      let date = calendar.date(byAdding: .day, value: daysOffset % (5 * 365), to: startDate)!
      let value = (10000 + (i * 37) % 50000) * 100  // $100-$600 range in cents

      let record = InvestmentValueRecord(
        id: id, accountId: accountId, date: date,
        value: value, currencyCode: currency.code)
      context.insert(record)
    }
  }
}
```

- [ ] **Step 2: Add a test to verify fixture seeding works**

Update `MoolahBenchmarks/BenchmarkSmokeTest.swift` — add a test that seeds 1x data and verifies counts:

```swift
func testFixtureSeedingProducesExpectedCounts_1x() throws {
  let result = try TestBackend.create()
  let context = result.container.mainContext
  BenchmarkFixtures.seed(scale: .x1, in: result.container)

  let txnCount = try context.fetchCount(FetchDescriptor<TransactionRecord>())
  let accountCount = try context.fetchCount(FetchDescriptor<AccountRecord>())
  let categoryCount = try context.fetchCount(FetchDescriptor<CategoryRecord>())

  XCTAssertEqual(txnCount, 18_662)
  XCTAssertEqual(accountCount, 31)
  XCTAssertEqual(categoryCount, 158)
}
```

- [ ] **Step 3: Build and run**

Run:
```bash
just benchmark BenchmarkSmokeTest
```
Expected: Both smoke tests pass. The seeding test confirms correct record counts.

- [ ] **Step 4: Commit**

```bash
git add MoolahBenchmarks/
git commit -m "feat: add BenchmarkFixtures with realistic data seeding at 1x/2x scale"
```

---

### Task 3: Transaction Fetch Benchmarks

The most important benchmarks — these measure the operation that powers the transaction list view.

**Files:**
- Create: `MoolahBenchmarks/TransactionFetchBenchmarks.swift`

- [ ] **Step 1: Create the async bridging helper**

Create `MoolahBenchmarks/Support/BenchmarkHelpers.swift`:

```swift
import Foundation

/// Bridges async code into synchronous XCTest measure blocks.
/// Blocks the calling thread until the MainActor work completes.
/// Only for use in benchmarks — never in production code.
func awaitSync<T>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
  let semaphore = DispatchSemaphore(value: 0)
  nonisolated(unsafe) var result: Result<T, Error>!
  Task { @MainActor in
    do {
      result = .success(try await work())
    } catch {
      result = .failure(error)
    }
    semaphore.signal()
  }
  semaphore.wait()
  return try result.get()
}
```

- [ ] **Step 2: Create TransactionFetchBenchmarks at 1x scale**

Create `MoolahBenchmarks/TransactionFetchBenchmarks.swift`:

```swift
import SwiftData
import XCTest

@testable import Moolah

/// Benchmarks for CloudKitTransactionRepository.fetch() at 1x scale (18k transactions).
/// Measures the most common fetch patterns used by the transaction list view.
final class TransactionFetchBenchmarks_1x: XCTestCase {
  private var backend: CloudKitBackend!
  private var container: ModelContainer!

  override func setUpWithError() throws {
    let result = try TestBackend.create()
    backend = result.backend
    container = result.container
    BenchmarkFixtures.seed(scale: .x1, in: container)
  }

  override func tearDownWithError() throws {
    backend = nil
    container = nil
  }

  private var metrics: [XCTMetric] { [XCTClockMetric(), XCTMemoryMetric()] }

  private var options: XCTMeasureOptions {
    let opts = XCTMeasureOptions()
    opts.iterationCount = 10
    return opts
  }

  /// Fetch page 0 for the busiest account (~7k transactions matching).
  func testFetchByAccount() {
    let repo = backend.transactions
    let filter = TransactionFilter(accountId: BenchmarkFixtures.heavyAccountId)

    measure(metrics: metrics, options: options) {
      _ = try! awaitSync {
        try await repo.fetch(filter: filter, page: 0, pageSize: 50)
      }
    }
  }

  /// Fetch all non-scheduled transactions (the default filter).
  func testFetchAllNonScheduled() {
    let repo = backend.transactions
    let filter = TransactionFilter(scheduled: false)

    measure(metrics: metrics, options: options) {
      _ = try! awaitSync {
        try await repo.fetch(filter: filter, page: 0, pageSize: 50)
      }
    }
  }

  /// Fetch with a date range (one year of transactions).
  func testFetchWithDateRange() {
    let repo = backend.transactions
    let calendar = Calendar.current
    let end = Date()
    let start = calendar.date(byAdding: .year, value: -1, to: end)!
    let filter = TransactionFilter(
      accountId: BenchmarkFixtures.heavyAccountId,
      dateRange: start...end
    )

    measure(metrics: metrics, options: options) {
      _ = try! awaitSync {
        try await repo.fetch(filter: filter, page: 0, pageSize: 50)
      }
    }
  }

  /// Fetch with category filter (exercises the in-memory post-filter path).
  func testFetchWithCategoryFilter() {
    let repo = backend.transactions
    // Use a handful of category IDs — matches real usage of filtering by a category group
    let categoryIds: Set<UUID> = Set(
      (0..<5).map {
        UUID(uuidString: "10000000-0000-0000-0000-\(String(format: "%012d", $0))")!
      }
    )
    let filter = TransactionFilter(
      accountId: BenchmarkFixtures.heavyAccountId,
      categoryIds: categoryIds
    )

    measure(metrics: metrics, options: options) {
      _ = try! awaitSync {
        try await repo.fetch(filter: filter, page: 0, pageSize: 50)
      }
    }
  }

  /// Fetch page 10 to measure offset/pagination cost.
  func testFetchDeepPagination() {
    let repo = backend.transactions
    let filter = TransactionFilter(accountId: BenchmarkFixtures.heavyAccountId)

    measure(metrics: metrics, options: options) {
      _ = try! awaitSync {
        try await repo.fetch(filter: filter, page: 10, pageSize: 50)
      }
    }
  }
}

/// Same benchmarks at 2x scale (37k transactions) for scaling analysis.
final class TransactionFetchBenchmarks_2x: XCTestCase {
  private var backend: CloudKitBackend!
  private var container: ModelContainer!

  override func setUpWithError() throws {
    let result = try TestBackend.create()
    backend = result.backend
    container = result.container
    BenchmarkFixtures.seed(scale: .x2, in: container)
  }

  override func tearDownWithError() throws {
    backend = nil
    container = nil
  }

  private var metrics: [XCTMetric] { [XCTClockMetric(), XCTMemoryMetric()] }

  private var options: XCTMeasureOptions {
    let opts = XCTMeasureOptions()
    opts.iterationCount = 10
    return opts
  }

  func testFetchByAccount() {
    let repo = backend.transactions
    let filter = TransactionFilter(accountId: BenchmarkFixtures.heavyAccountId)

    measure(metrics: metrics, options: options) {
      _ = try! awaitSync {
        try await repo.fetch(filter: filter, page: 0, pageSize: 50)
      }
    }
  }

  func testFetchAllNonScheduled() {
    let repo = backend.transactions
    let filter = TransactionFilter(scheduled: false)

    measure(metrics: metrics, options: options) {
      _ = try! awaitSync {
        try await repo.fetch(filter: filter, page: 0, pageSize: 50)
      }
    }
  }

  func testFetchWithDateRange() {
    let repo = backend.transactions
    let calendar = Calendar.current
    let end = Date()
    let start = calendar.date(byAdding: .year, value: -1, to: end)!
    let filter = TransactionFilter(
      accountId: BenchmarkFixtures.heavyAccountId,
      dateRange: start...end
    )

    measure(metrics: metrics, options: options) {
      _ = try! awaitSync {
        try await repo.fetch(filter: filter, page: 0, pageSize: 50)
      }
    }
  }

  func testFetchWithCategoryFilter() {
    let repo = backend.transactions
    let categoryIds: Set<UUID> = Set(
      (0..<5).map {
        UUID(uuidString: "10000000-0000-0000-0000-\(String(format: "%012d", $0))")!
      }
    )
    let filter = TransactionFilter(
      accountId: BenchmarkFixtures.heavyAccountId,
      categoryIds: categoryIds
    )

    measure(metrics: metrics, options: options) {
      _ = try! awaitSync {
        try await repo.fetch(filter: filter, page: 0, pageSize: 50)
      }
    }
  }

  func testFetchDeepPagination() {
    let repo = backend.transactions
    let filter = TransactionFilter(accountId: BenchmarkFixtures.heavyAccountId)

    measure(metrics: metrics, options: options) {
      _ = try! awaitSync {
        try await repo.fetch(filter: filter, page: 10, pageSize: 50)
      }
    }
  }
}
```

- [ ] **Step 3: Build and run**

Run:
```bash
just benchmark TransactionFetchBenchmarks_1x
```
Expected: All 5 benchmarks run and produce timing output. Record the numbers.

Run:
```bash
just benchmark TransactionFetchBenchmarks_2x
```
Expected: All 5 benchmarks run. Compare 2x times to 1x — the ratio reveals scaling behavior.

- [ ] **Step 4: Commit**

```bash
git add MoolahBenchmarks/
git commit -m "feat: add transaction fetch benchmarks at 1x and 2x scale"
```

---

### Task 4: Balance and Account Fetch Benchmarks

Measures balance computation (the priorBalance reduction) and account fetchAll when cached balances are invalidated (the post-sync path).

**Files:**
- Create: `MoolahBenchmarks/BalanceBenchmarks.swift`

- [ ] **Step 1: Create BalanceBenchmarks**

Create `MoolahBenchmarks/BalanceBenchmarks.swift`:

```swift
import SwiftData
import XCTest

@testable import Moolah

/// Benchmarks for balance computation — both the priorBalance reduction in transaction
/// fetch and the full account fetchAll with invalidated cached balances.
final class BalanceBenchmarks_1x: XCTestCase {
  private var backend: CloudKitBackend!
  private var container: ModelContainer!

  override func setUpWithError() throws {
    let result = try TestBackend.create()
    backend = result.backend
    container = result.container
    BenchmarkFixtures.seed(scale: .x1, in: container)
  }

  override func tearDownWithError() throws {
    backend = nil
    container = nil
  }

  private var metrics: [XCTMetric] { [XCTClockMetric(), XCTMemoryMetric()] }

  private var options: XCTMeasureOptions {
    let opts = XCTMeasureOptions()
    opts.iterationCount = 10
    return opts
  }

  /// Account fetchAll when all cachedBalance values are nil.
  /// This triggers recomputeAllBalances which sums transactions per account.
  func testAccountFetchAllWithInvalidatedBalances() {
    let repo = backend.accounts

    measure(metrics: metrics, options: options) {
      // Invalidate all cached balances before each iteration
      let context = self.container.mainContext
      let accounts = try! context.fetch(FetchDescriptor<AccountRecord>())
      for account in accounts {
        account.cachedBalance = nil
      }
      try! context.save()

      _ = try! awaitSync { try await repo.fetchAll() }
    }
  }

  /// Transaction fetch for the heaviest account — implicitly measures priorBalance
  /// reduction since fetch() sums all transactions after the page.
  func testFetchHeavyAccountPriorBalance() {
    let repo = backend.transactions
    let filter = TransactionFilter(accountId: BenchmarkFixtures.heavyAccountId)

    // Fetch page 0 — priorBalance sums all records from index 50 to ~7000
    measure(metrics: metrics, options: options) {
      _ = try! awaitSync {
        try await repo.fetch(filter: filter, page: 0, pageSize: 50)
      }
    }
  }
}

final class BalanceBenchmarks_2x: XCTestCase {
  private var backend: CloudKitBackend!
  private var container: ModelContainer!

  override func setUpWithError() throws {
    let result = try TestBackend.create()
    backend = result.backend
    container = result.container
    BenchmarkFixtures.seed(scale: .x2, in: container)
  }

  override func tearDownWithError() throws {
    backend = nil
    container = nil
  }

  private var metrics: [XCTMetric] { [XCTClockMetric(), XCTMemoryMetric()] }

  private var options: XCTMeasureOptions {
    let opts = XCTMeasureOptions()
    opts.iterationCount = 10
    return opts
  }

  func testAccountFetchAllWithInvalidatedBalances() {
    let repo = backend.accounts

    measure(metrics: metrics, options: options) {
      let context = self.container.mainContext
      let accounts = try! context.fetch(FetchDescriptor<AccountRecord>())
      for account in accounts {
        account.cachedBalance = nil
      }
      try! context.save()

      _ = try! awaitSync { try await repo.fetchAll() }
    }
  }

  func testFetchHeavyAccountPriorBalance() {
    let repo = backend.transactions
    let filter = TransactionFilter(accountId: BenchmarkFixtures.heavyAccountId)

    measure(metrics: metrics, options: options) {
      _ = try! awaitSync {
        try await repo.fetch(filter: filter, page: 0, pageSize: 50)
      }
    }
  }
}
```

- [ ] **Step 2: Build and run**

Run:
```bash
just benchmark BalanceBenchmarks_1x
```
Expected: Both benchmarks produce timing output.

- [ ] **Step 3: Commit**

```bash
git add MoolahBenchmarks/BalanceBenchmarks.swift
git commit -m "feat: add balance computation and account fetch benchmarks"
```

---

### Task 5: toDomain Conversion Benchmarks

Isolates the per-record conversion cost, including `Currency.from(code:)` which creates a `NumberFormatter` on every call.

**Files:**
- Create: `MoolahBenchmarks/ConversionBenchmarks.swift`

- [ ] **Step 1: Create ConversionBenchmarks**

Create `MoolahBenchmarks/ConversionBenchmarks.swift`:

```swift
import SwiftData
import XCTest

@testable import Moolah

/// Benchmarks for TransactionRecord.toDomain() conversion.
/// Isolates the per-record cost including Currency.from(code:) which allocates
/// a NumberFormatter on every call.
final class ConversionBenchmarks: XCTestCase {
  private var container: ModelContainer!
  private var records1k: [TransactionRecord] = []
  private var records5k: [TransactionRecord] = []

  override func setUpWithError() throws {
    let result = try TestBackend.create()
    container = result.container

    // Seed enough data to fetch from
    BenchmarkFixtures.seed(scale: .x1, in: container)

    // Pre-fetch records so the measure block only times conversion, not the fetch
    let context = container.mainContext
    var descriptor = FetchDescriptor<TransactionRecord>()
    descriptor.fetchLimit = 5000
    let allRecords = try context.fetch(descriptor)

    records1k = Array(allRecords.prefix(1000))
    records5k = Array(allRecords.prefix(5000))
  }

  override func tearDownWithError() throws {
    container = nil
    records1k = []
    records5k = []
  }

  private var metrics: [XCTMetric] { [XCTClockMetric(), XCTMemoryMetric()] }

  private var options: XCTMeasureOptions {
    let opts = XCTMeasureOptions()
    opts.iterationCount = 10
    return opts
  }

  func testToDomain_1000records() {
    let records = self.records1k

    measure(metrics: metrics, options: options) {
      autoreleasepool {
        let result = records.map { $0.toDomain() }
        _ = result.count
      }
    }
  }

  func testToDomain_5000records() {
    let records = self.records5k

    measure(metrics: metrics, options: options) {
      autoreleasepool {
        let result = records.map { $0.toDomain() }
        _ = result.count
      }
    }
  }
}
```

- [ ] **Step 2: Build and run**

Run:
```bash
just benchmark ConversionBenchmarks
```
Expected: Both benchmarks produce timing output. Compare 5k/1k ratio — should be close to 5x for linear scaling. If significantly higher, `Currency.from(code:)` or something else is scaling poorly.

- [ ] **Step 3: Commit**

```bash
git add MoolahBenchmarks/ConversionBenchmarks.swift
git commit -m "feat: add toDomain conversion benchmarks"
```

---

### Task 6: Sync Batch Benchmarks

Measures batch upsert (download) and record lookup (upload) — the sync operations that cause UI jitter.

**Files:**
- Create: `MoolahBenchmarks/SyncBatchBenchmarks.swift`

- [ ] **Step 1: Create SyncBatchBenchmarks**

The sync engine methods (`applyBatchSaves`, `buildBatchRecordLookup`) are private. We benchmark the public entry points: `applyRemoteChanges` for download and test batch upsert logic directly via the static methods by making them `internal` for `@testable import`.

First, check if `applyBatchSaves` is accessible via `@testable import`. If it is (since it's `private` not `fileprivate`, and the class is in the same module), we can call it. If not, we benchmark through `applyRemoteChanges`.

Since `applyBatchSaves` and `batchUpsertTransactions` are `private static`, they are not accessible even with `@testable import`. The benchmarks must work through the public `applyRemoteChanges` method, or we need to change access to `internal`. The simplest approach: change the `private` on the batch methods to no access modifier (internal) so `@testable import` can reach them.

Create `MoolahBenchmarks/SyncBatchBenchmarks.swift`:

```swift
import CloudKit
import SwiftData
import XCTest

@testable import Moolah

/// Benchmarks for sync batch operations — upsert (download) and balance invalidation.
/// Tests both insert-heavy (first sync) and update-heavy (subsequent sync) scenarios.
final class SyncBatchBenchmarks_1x: XCTestCase {
  private var container: ModelContainer!

  override func setUpWithError() throws {
    let result = try TestBackend.create()
    container = result.container
    BenchmarkFixtures.seed(scale: .x1, in: container)
  }

  override func tearDownWithError() throws {
    container = nil
  }

  private var metrics: [XCTMetric] { [XCTClockMetric(), XCTMemoryMetric()] }

  private var options: XCTMeasureOptions {
    let opts = XCTMeasureOptions()
    opts.iterationCount = 10
    return opts
  }

  /// Simulates upserting 400 NEW transaction records into an 18k dataset.
  func testBatchUpsert_insertHeavy() {
    let context = container.mainContext

    measure(metrics: metrics, options: options) {
      // Create 400 fresh TransactionRecords that don't exist in the store
      let batchId = UUID().uuidString.prefix(8)
      var records: [TransactionRecord] = []
      for i in 0..<400 {
        let record = TransactionRecord(
          id: UUID(),
          type: TransactionType.expense.rawValue,
          date: Date(),
          accountId: BenchmarkFixtures.heavyAccountId,
          amount: -(i + 1) * 100,
          currencyCode: Currency.defaultTestCurrency.code,
          payee: "Bench-\(batchId)-\(i)"
        )
        records.append(record)
      }

      // Build lookup of existing records (this is the expensive part)
      let existing = (try? context.fetch(FetchDescriptor<TransactionRecord>())) ?? []
      var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

      for record in records {
        if byID[record.id] == nil {
          context.insert(record)
          byID[record.id] = record
        }
      }

      // Rollback to avoid accumulating records across iterations
      context.rollback()
    }
  }

  /// Simulates upserting 400 EXISTING transaction records (update path).
  func testBatchUpsert_updateHeavy() {
    let context = container.mainContext

    // Pre-fetch 400 existing IDs to update
    var descriptor = FetchDescriptor<TransactionRecord>()
    descriptor.fetchLimit = 400
    let existingIds = (try? context.fetch(descriptor))?.map(\.id) ?? []

    measure(metrics: metrics, options: options) {
      let existing = (try? context.fetch(FetchDescriptor<TransactionRecord>())) ?? []
      let byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

      for id in existingIds {
        if let record = byID[id] {
          record.payee = "Updated"
        }
      }

      context.rollback()
    }
  }

  /// Measures the balance invalidation that follows a transaction sync.
  func testBalanceInvalidation() {
    let context = container.mainContext

    measure(metrics: metrics, options: options) {
      let accounts = (try? context.fetch(FetchDescriptor<AccountRecord>())) ?? []
      for account in accounts {
        account.cachedBalance = nil
      }
      // Don't save — just measure the invalidation sweep
      context.rollback()
    }
  }
}

final class SyncBatchBenchmarks_2x: XCTestCase {
  private var container: ModelContainer!

  override func setUpWithError() throws {
    let result = try TestBackend.create()
    container = result.container
    BenchmarkFixtures.seed(scale: .x2, in: container)
  }

  override func tearDownWithError() throws {
    container = nil
  }

  private var metrics: [XCTMetric] { [XCTClockMetric(), XCTMemoryMetric()] }

  private var options: XCTMeasureOptions {
    let opts = XCTMeasureOptions()
    opts.iterationCount = 10
    return opts
  }

  func testBatchUpsert_insertHeavy() {
    let context = container.mainContext

    measure(metrics: metrics, options: options) {
      let batchId = UUID().uuidString.prefix(8)
      var records: [TransactionRecord] = []
      for i in 0..<400 {
        let record = TransactionRecord(
          id: UUID(),
          type: TransactionType.expense.rawValue,
          date: Date(),
          accountId: BenchmarkFixtures.heavyAccountId,
          amount: -(i + 1) * 100,
          currencyCode: Currency.defaultTestCurrency.code,
          payee: "Bench-\(batchId)-\(i)"
        )
        records.append(record)
      }

      let existing = (try? context.fetch(FetchDescriptor<TransactionRecord>())) ?? []
      var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

      for record in records {
        if byID[record.id] == nil {
          context.insert(record)
          byID[record.id] = record
        }
      }

      context.rollback()
    }
  }

  func testBatchUpsert_updateHeavy() {
    let context = container.mainContext

    var descriptor = FetchDescriptor<TransactionRecord>()
    descriptor.fetchLimit = 400
    let existingIds = (try? context.fetch(descriptor))?.map(\.id) ?? []

    measure(metrics: metrics, options: options) {
      let existing = (try? context.fetch(FetchDescriptor<TransactionRecord>())) ?? []
      let byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

      for id in existingIds {
        if let record = byID[id] {
          record.payee = "Updated"
        }
      }

      context.rollback()
    }
  }

  func testBalanceInvalidation() {
    let context = container.mainContext

    measure(metrics: metrics, options: options) {
      let accounts = (try? context.fetch(FetchDescriptor<AccountRecord>())) ?? []
      for account in accounts {
        account.cachedBalance = nil
      }
      context.rollback()
    }
  }
}
```

- [ ] **Step 2: Build and run**

Run:
```bash
just benchmark SyncBatchBenchmarks_1x
```
Expected: All 3 benchmarks produce timing output. The insert-heavy test is the critical one — it simulates initial sync.

- [ ] **Step 3: Commit**

```bash
git add MoolahBenchmarks/SyncBatchBenchmarks.swift
git commit -m "feat: add sync batch upsert and balance invalidation benchmarks"
```

---

### Task 7: Signpost Instrumentation — Transaction Repository

Add coarse and fine-grained signposts to `CloudKitTransactionRepository`, the primary hot path.

**Files:**
- Modify: `Backends/CloudKit/Repositories/CloudKitTransactionRepository.swift`

- [ ] **Step 1: Add import and coarse signpost to fetch()**

At the top of `CloudKitTransactionRepository.swift`, add `import os` after the existing imports.

Then wrap the `fetch` method body with signposts. The method currently looks like:

```swift
func fetch(filter: TransactionFilter, page: Int, pageSize: Int) async throws -> TransactionPage {
    return try await MainActor.run {
```

Change to:

```swift
func fetch(filter: TransactionFilter, page: Int, pageSize: Int) async throws -> TransactionPage {
    let signpostID = OSSignpostID(log: Signposts.repository)
    os_signpost(.begin, log: Signposts.repository, name: "TransactionRepo.fetch", signpostID: signpostID)
    defer { os_signpost(.end, log: Signposts.repository, name: "TransactionRepo.fetch", signpostID: signpostID) }

    return try await MainActor.run {
```

- [ ] **Step 2: Add fine-grained signposts inside fetch()**

Inside the `MainActor.run` block, wrap each major phase. Use the same `signpostID` (it's captured by the closure).

Around the predicate fetch section (the `if let filterAccountId` block, lines ~32-56):
```swift
os_signpost(.begin, log: Signposts.repository, name: "fetch.predicateQuery", signpostID: signpostID)
// ... existing predicate fetch code ...
os_signpost(.end, log: Signposts.repository, name: "fetch.predicateQuery", signpostID: signpostID)
```

Around the in-memory post-filter section (the `var filteredRecords = mergedRecords` through payee filter, lines ~78-105):
```swift
os_signpost(.begin, log: Signposts.repository, name: "fetch.postFilter", signpostID: signpostID)
// ... existing filter code ...
os_signpost(.end, log: Signposts.repository, name: "fetch.postFilter", signpostID: signpostID)
```

Around the sort (lines ~108-111):
```swift
os_signpost(.begin, log: Signposts.repository, name: "fetch.sort", signpostID: signpostID)
filteredRecords.sort { ... }
os_signpost(.end, log: Signposts.repository, name: "fetch.sort", signpostID: signpostID)
```

Around the toDomain conversion (line ~125):
```swift
os_signpost(.begin, log: Signposts.repository, name: "fetch.toDomain", signpostID: signpostID)
let pageTransactions = pageRecords.map { $0.toDomain() }
os_signpost(.end, log: Signposts.repository, name: "fetch.toDomain", signpostID: signpostID)
```

Around the priorBalance reduction (line ~128):
```swift
os_signpost(.begin, log: Signposts.balance, name: "fetch.priorBalance", signpostID: signpostID)
let priorBalanceCents = filteredRecords[end...].reduce(0) { $0 + $1.amount }
os_signpost(.end, log: Signposts.balance, name: "fetch.priorBalance", signpostID: signpostID)
```

- [ ] **Step 3: Add coarse signposts to create, update, delete, fetchPayeeSuggestions**

Each gets the same pattern — begin/end pair wrapping the method body:

```swift
func create(_ transaction: Transaction) async throws -> Transaction {
    let signpostID = OSSignpostID(log: Signposts.repository)
    os_signpost(.begin, log: Signposts.repository, name: "TransactionRepo.create", signpostID: signpostID)
    defer { os_signpost(.end, log: Signposts.repository, name: "TransactionRepo.create", signpostID: signpostID) }
    // ... existing body unchanged
```

Same for `update`, `delete`, and `fetchPayeeSuggestions` — changing the name string for each.

- [ ] **Step 4: Build**

Run:
```bash
just build-mac
```
Expected: Compiles without warnings or errors.

- [ ] **Step 5: Commit**

```bash
git add Backends/CloudKit/Repositories/CloudKitTransactionRepository.swift
git commit -m "feat: add signpost instrumentation to CloudKitTransactionRepository"
```

---

### Task 8: Signpost Instrumentation — Other Repositories

Add coarse signposts to the account, category, and earmark repositories.

**Files:**
- Modify: `Backends/CloudKit/Repositories/CloudKitAccountRepository.swift`
- Modify: `Backends/CloudKit/Repositories/CloudKitCategoryRepository.swift`
- Modify: `Backends/CloudKit/Repositories/CloudKitEarmarkRepository.swift`

- [ ] **Step 1: Add signposts to CloudKitAccountRepository**

Add `import os` at the top.

Add coarse signposts to each public method: `fetchAll`, `create`, `update`, `delete`.

For `fetchAll`, also add a fine-grained signpost around the `recomputeAllBalances` call since that's a known hot path:

```swift
func fetchAll() async throws -> [Account] {
    let signpostID = OSSignpostID(log: Signposts.repository)
    os_signpost(.begin, log: Signposts.repository, name: "AccountRepo.fetchAll", signpostID: signpostID)
    defer { os_signpost(.end, log: Signposts.repository, name: "AccountRepo.fetchAll", signpostID: signpostID) }

    let descriptor = FetchDescriptor<AccountRecord>(
      sortBy: [SortDescriptor(\.position)]
    )
    return try await MainActor.run {
      let records = try context.fetch(descriptor)

      if records.contains(where: { $0.cachedBalance == nil }) {
        os_signpost(.begin, log: Signposts.balance, name: "recomputeAllBalances", signpostID: signpostID)
        try recomputeAllBalances(records: records)
        os_signpost(.end, log: Signposts.balance, name: "recomputeAllBalances", signpostID: signpostID)
      }
      // ... rest unchanged
```

- [ ] **Step 2: Add signposts to CloudKitCategoryRepository**

Add `import os` at the top. Add coarse signposts to `fetchAll`, `create`, `update`, `delete`.

- [ ] **Step 3: Add signposts to CloudKitEarmarkRepository**

Add `import os` at the top. Add coarse signposts to `fetchAll`, `create`, `update`, `delete`, `fetchBudget`, `setBudget`.

- [ ] **Step 4: Build**

Run:
```bash
just build-mac
```
Expected: Compiles without warnings or errors.

- [ ] **Step 5: Commit**

```bash
git add Backends/CloudKit/Repositories/
git commit -m "feat: add signpost instrumentation to account, category, and earmark repositories"
```

---

### Task 9: Signpost Instrumentation — ProfileSyncEngine

Add coarse and fine-grained signposts to the sync engine.

**Files:**
- Modify: `Backends/CloudKit/Sync/ProfileSyncEngine.swift`

- [ ] **Step 1: Add import**

Add `import os` to the imports at the top of `ProfileSyncEngine.swift` (after `import OSLog`). Note: The file already imports `OSLog` for `Logger` — `os_signpost` requires `import os`.

- [ ] **Step 2: Add coarse signposts to public sync methods**

Add begin/end pairs to: `applyRemoteChanges`, `sendChanges`, `fetchChanges`, `queueAllExistingRecords`.

For `applyRemoteChanges` (line ~249):
```swift
func applyRemoteChanges(
    saved: [CKRecord],
    deleted: [(CKRecord.ID, String)]
  ) {
    let signpostID = OSSignpostID(log: Signposts.sync)
    os_signpost(.begin, log: Signposts.sync, name: "applyRemoteChanges", signpostID: signpostID,
      "%{public}d saves, %{public}d deletes", saved.count, deleted.count)
    defer { os_signpost(.end, log: Signposts.sync, name: "applyRemoteChanges", signpostID: signpostID) }
    // ... rest unchanged
```

For `sendChanges` (line ~185):
```swift
func sendChanges() async {
    let signpostID = OSSignpostID(log: Signposts.sync)
    os_signpost(.begin, log: Signposts.sync, name: "sendChanges", signpostID: signpostID)
    defer { os_signpost(.end, log: Signposts.sync, name: "sendChanges", signpostID: signpostID) }
    // ... rest unchanged
```

Same pattern for `fetchChanges` and `queueAllExistingRecords`.

- [ ] **Step 3: Add fine-grained signposts inside applyRemoteChanges**

Inside `applyRemoteChanges`, wrap the sub-steps:

Around `applyBatchSaves` call (line ~271):
```swift
os_signpost(.begin, log: Signposts.sync, name: "applyBatchSaves", signpostID: signpostID,
  "%{public}d records", saved.count)
Self.applyBatchSaves(saved, context: context)
os_signpost(.end, log: Signposts.sync, name: "applyBatchSaves", signpostID: signpostID)
```

Around `applyBatchDeletions` call (line ~272):
```swift
os_signpost(.begin, log: Signposts.sync, name: "applyBatchDeletions", signpostID: signpostID,
  "%{public}d records", deleted.count)
Self.applyBatchDeletions(deleted, context: context)
os_signpost(.end, log: Signposts.sync, name: "applyBatchDeletions", signpostID: signpostID)
```

Around `invalidateCachedBalances` (line ~280):
```swift
os_signpost(.begin, log: Signposts.balance, name: "invalidateCachedBalances", signpostID: signpostID)
Self.invalidateCachedBalances(context: context)
os_signpost(.end, log: Signposts.balance, name: "invalidateCachedBalances", signpostID: signpostID)
```

Around `context.save()` (line ~284):
```swift
os_signpost(.begin, log: Signposts.sync, name: "contextSave", signpostID: signpostID)
try context.save()
os_signpost(.end, log: Signposts.sync, name: "contextSave", signpostID: signpostID)
```

- [ ] **Step 4: Add signpost to nextRecordZoneChangeBatch**

In `nextRecordZoneChangeBatchOnMain` (line ~678), add:

```swift
private func nextRecordZoneChangeBatchOnMain(
    _ context: CKSyncEngine.SendChangesContext,
    syncEngine: CKSyncEngine
  ) -> CKSyncEngine.RecordZoneChangeBatch? {
    let signpostID = OSSignpostID(log: Signposts.sync)
    os_signpost(.begin, log: Signposts.sync, name: "nextRecordZoneChangeBatch", signpostID: signpostID)
    defer { os_signpost(.end, log: Signposts.sync, name: "nextRecordZoneChangeBatch", signpostID: signpostID) }
    // ... rest unchanged
```

And wrap `buildBatchRecordLookup` call (line ~714):
```swift
os_signpost(.begin, log: Signposts.sync, name: "buildBatchRecordLookup", signpostID: signpostID,
  "%{public}d UUIDs", saveRecordIDs.count)
let recordLookup = buildBatchRecordLookup(for: Set(saveRecordIDs.map(\.1)))
os_signpost(.end, log: Signposts.sync, name: "buildBatchRecordLookup", signpostID: signpostID)
```

- [ ] **Step 5: Build**

Run:
```bash
just build-mac
```
Expected: Compiles without warnings or errors.

- [ ] **Step 6: Commit**

```bash
git add Backends/CloudKit/Sync/ProfileSyncEngine.swift
git commit -m "feat: add signpost instrumentation to ProfileSyncEngine"
```

---

### Task 10: Run All Benchmarks and Record Baseline

Run the complete benchmark suite, record the initial numbers, and verify everything works end-to-end.

**Files:** None (verification only)

- [ ] **Step 1: Run all benchmarks**

Run:
```bash
mkdir -p .agent-tmp
just benchmark 2>&1 | tee .agent-tmp/benchmark-output.txt
```
Expected: All benchmarks complete without errors.

- [ ] **Step 2: Extract and review results**

Run:
```bash
grep -A2 "measured" .agent-tmp/benchmark-output.txt
```

For each benchmark, check:
- Does the stddev look reasonable (< 20%)?
- Do the 2x results scale linearly compared to 1x?
- Are there any surprising outliers?

Record the results in the PR description or commit message for reference.

- [ ] **Step 3: Clean up**

```bash
rm .agent-tmp/benchmark-output.txt
```

- [ ] **Step 4: Final commit if any adjustments were needed**

If any benchmarks needed tweaking (noisy tests, broken assertions), commit the fixes:
```bash
git add -A
git commit -m "fix: adjust benchmarks based on initial run results"
```

---

### Task 11: Delete Smoke Test and Final Cleanup

Remove the temporary smoke test (its purpose was to verify the target builds) and ensure all files are clean.

**Files:**
- Delete: `MoolahBenchmarks/BenchmarkSmokeTest.swift`

- [ ] **Step 1: Remove the smoke test**

Delete `MoolahBenchmarks/BenchmarkSmokeTest.swift` — the fixture seeding verification is now covered by the actual benchmarks running successfully. The target-builds check is validated by every benchmark run.

- [ ] **Step 2: Run benchmarks one final time**

Run:
```bash
just benchmark 2>&1 | tail -5
```
Expected: All tests pass, no missing test class errors.

- [ ] **Step 3: Commit**

```bash
git rm MoolahBenchmarks/BenchmarkSmokeTest.swift
git commit -m "chore: remove smoke test, benchmark suite is complete"
```
