# Instrument Registry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate `NSUbiquitousKeyValueStore` usage and introduce a per-profile CloudKit-synced instrument registry covering stocks + crypto (fiat mix-in). Per the design at [`plans/2026-04-24-instrument-registry-design.md`](./2026-04-24-instrument-registry-design.md).

**Architecture:** 16 tasks across five phases. **Phase A (1)** fixes the `Instrument.stock` id convention. **Phase B (2)** bumps `InstrumentRecord` schema and its CloudKit round-trip. **Phase C (3–8)** lays down the new Domain protocols, backend implementations, and the search service — additive, each independent. **Phase D (9–14)** rewires the existing services, stores, and views through the new registry. **Phase E (15–16)** deletes the obsolete code and does the post-merge sanity sweep. Each task lands as a separate PR via the merge queue skill.

**Tech Stack:** Swift 6.2, SwiftUI, SwiftData, CloudKit (`CKSyncEngine`), swift-testing (`@Suite`, `@Test`, `#expect`), XCUITest (macOS), `@Observable`, `@MainActor`, `@Model`, xcodegen, `just`.

---

## How to execute this plan

Per-task workflow:

1. Create a new worktree + branch off `main` via the `superpowers:using-git-worktrees` skill (`.worktrees/` directory, already gitignored).
2. Execute the task's steps in order. TDD where the task lists test-first steps.
3. Before committing code, run `just format` to apply swift-format + SwiftLint autocorrect.
4. After adding / deleting Swift files, run `just generate` so xcodegen rebuilds `Moolah.xcodeproj`.
5. Run the scoped tests listed in the task. Pipe output through `tee .agent-tmp/<task>-test.txt` so failures are inspectable without re-running. Delete the temp file when done.
6. Run `@code-review`. For any task touching CloudKit sync or repositories, also run `@concurrency-review` and `@sync-review`. For any change to aggregation / conversion, run `@instrument-conversion-review`. Address critical findings before committing.
7. Commit with the conventional-commit message provided in the task.
8. Push the branch and open a PR titled "Task N of `plans/2026-04-24-instrument-registry-implementation.md`" referencing the design. Enqueue via the merge-queue skill.
9. Wait for merge. Start a fresh worktree off updated `main` for the next task.

**Tests use swift-testing.** Suites are `@Suite("Name") struct FooTests { ... }` with `@Test func name() { #expect(condition) }`. Async / `@MainActor` isolation is applied per-test or per-suite as needed.

**Concurrency.** Stores are `@MainActor @Observable`. Repositories follow the existing `@unchecked Sendable` + `@MainActor` discipline of `CloudKitAccountRepository` / `CloudKitTransactionRepository`. The new `InstrumentSearchService` is a `struct Sendable`.

**Test output capture.** Run `mkdir -p .agent-tmp` at the start of each task. Use `| tee .agent-tmp/task<N>-<description>.txt` for any multi-second command.

---

## Task 1: Fix `Instrument.stock` id formula

Change the canonical stock id from `"EXCHANGE:NAME"` to `"EXCHANGE:TICKER"`. `ticker` is the Yahoo API lookup key and is what the picker's search flow will know. `name` is a display concern that shouldn't influence identity.

**Files:**
- Modify: `Domain/Models/Instrument.swift:54-66` — the `stock(ticker:exchange:name:decimals:)` factory.
- Modify: `MoolahTests/Domain/InstrumentStockTests.swift` — existing test expectations.
- Modify: `MoolahTests/Features/ReportingStoreTestsMore.swift`, `MoolahTests/Features/ReportingStoreTests.swift`, `MoolahTests/Features/Import/ImportStoreTestsMoreSecondHalf.swift`, `MoolahTests/Shared/CostBasisEngineTests.swift`, `MoolahTests/Shared/CapitalGainsCalculatorTestsMoreExtra.swift` — any test that compares against a literal stock id.
- No production code outside `Instrument.swift` needs to change because every other caller goes through `Instrument.stock(...)`.

- [ ] **Step 1: Find every hardcoded literal stock id in tests**

```bash
mkdir -p .agent-tmp
grep -rn "\"ASX:\|\"NASDAQ:\|\"NYSE:\|\"LSE:" MoolahTests Features Backends Domain Shared 2>&1 | tee .agent-tmp/task1-literals.txt
```

Expected: a list of test files with literal IDs like `"ASX:BHP"`, `"ASX:CBA"`, `"NASDAQ:Apple"`. Also inspect the two sync-code comments in `Backends/CloudKit/Sync/ProfileDataSyncHandler+{RecordLookup,SystemFields}.swift` (they mention `"ASX:BHP"` as an example — update those too).

- [ ] **Step 2: Update the failing test expectation first (TDD)**

Modify `MoolahTests/Domain/InstrumentStockTests.swift`:

```swift
@Test
func stockInstrumentProperties() {
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
  #expect(bhp.id == "ASX:BHP.AX")  // was "ASX:BHP"
  #expect(bhp.kind == .stock)
  #expect(bhp.name == "BHP")
  #expect(bhp.decimals == 0)
  #expect(bhp.ticker == "BHP.AX")
  #expect(bhp.exchange == "ASX")
  #expect(bhp.chainId == nil)
  #expect(bhp.contractAddress == nil)
}

@Test
func stockIdUsesExchangeColonTicker() {
  let aapl = Instrument.stock(ticker: "AAPL", exchange: "NASDAQ", name: "Apple")
  #expect(aapl.id == "NASDAQ:AAPL")  // was "NASDAQ:Apple"
}

@Test
func stockIdIsIndependentOfName() {
  // Identity is (exchange, ticker); name is display-only.
  let short = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
  let long = Instrument.stock(
    ticker: "BHP.AX", exchange: "ASX", name: "BHP Group Limited")
  #expect(short.id == long.id)
  #expect(short.name != long.name)
}

@Test
func stockIdChangesWithTickerEvenForSameName() {
  // Two BHP listings on different exchanges with different tickers.
  let aud = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
  let lon = Instrument.stock(ticker: "BHP.L", exchange: "LSE", name: "BHP")
  #expect(aud.id != lon.id)
  #expect(aud.id == "ASX:BHP.AX")
  #expect(lon.id == "LSE:BHP.L")
}
```

Also rename the old `stockIdUsesExchangeColonName` test — there is no such invariant any more. Remove or rework any test that asserts `"ASX:BHP"` for a BHP stock (the value should be `"ASX:BHP.AX"` throughout).

- [ ] **Step 3: Run tests to verify expected failures**

```bash
just test InstrumentStockTests 2>&1 | tee .agent-tmp/task1-pre.txt
grep -i 'failed' .agent-tmp/task1-pre.txt
```

Expected: multiple failures with messages like `expected "ASX:BHP.AX", actual "ASX:BHP"`.

- [ ] **Step 4: Fix the factory**

In `Domain/Models/Instrument.swift`:

```swift
static func stock(
  ticker: String, exchange: String, name: String, decimals: Int = 0
) -> Instrument {
  Instrument(
    id: "\(exchange):\(ticker)",   // was "\(exchange):\(name)"
    kind: .stock,
    name: name,
    decimals: decimals,
    ticker: ticker,
    exchange: exchange,
    chainId: nil,
    contractAddress: nil
  )
}
```

Update the doc-comment directly above the factory to reflect the new convention.

- [ ] **Step 5: Run the InstrumentStockTests again**

```bash
just test InstrumentStockTests 2>&1 | tee .agent-tmp/task1-mid.txt
```

Expected: all pass.

- [ ] **Step 6: Update every literal stock id in the other test files**

Each file from Step 1's grep output — replace `"ASX:BHP"` → `"ASX:BHP.AX"`, `"ASX:CBA"` → `"ASX:CBA.AX"`, `"NASDAQ:Apple"` → `"NASDAQ:AAPL"`, `"NYSE:BRK-B"` → `"NYSE:BRK.B"`, `"NYSE:BRK-A"` → `"NYSE:BRK-A"` (ticker string happens to equal name here), and the `"ASX:\(name)"` interpolations in `CostBasisEngineTests.swift` / `CapitalGainsCalculatorTestsMoreExtra.swift` — those generate ids like `"ASX:BHP"` from a `name` variable; change the interpolation to use the ticker the test is constructing or pass the explicit id.

The two sync-code comments in `ProfileDataSyncHandler+RecordLookup.swift:42` and `ProfileDataSyncHandler+SystemFields.swift:51` should have their `"ASX:BHP"` example updated to `"ASX:BHP.AX"`.

- [ ] **Step 7: Run the full test suite**

```bash
just test 2>&1 | tee .agent-tmp/task1-full.txt
grep -iE 'failed|error:' .agent-tmp/task1-full.txt | head -40
```

Expected: clean.

- [ ] **Step 8: Format, generate, and commit**

```bash
just format
just generate
rm .agent-tmp/task1-*.txt
git add Domain/Models/Instrument.swift MoolahTests Backends/CloudKit/Sync/ProfileDataSyncHandler+RecordLookup.swift Backends/CloudKit/Sync/ProfileDataSyncHandler+SystemFields.swift
git commit -m "$(cat <<'EOF'
refactor(domain): use EXCHANGE:TICKER for stock instrument ids

Ticker is the Yahoo API lookup key and is what the upcoming
instrument-registry picker has to work with when a user types a
stock search; name is a display concern that shouldn't influence
identity. No users hold stock records today, so the id change is a
compiler-enforced update to ~30 test assertions with no data
migration.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Extend `InstrumentRecord` with crypto provider-mapping fields

Add three nullable fields to the SwiftData model, extend the `CloudKitRecordConvertible` round-trip, and update the `batchUpsertInstruments` field-copy so multi-device syncs preserve the new fields.

**Files:**
- Modify: `Backends/CloudKit/Models/InstrumentRecord.swift` — add three stored properties + init params.
- Modify: `Backends/CloudKit/Sync/InstrumentRecord+CloudKit.swift` — encode / decode the three fields.
- Modify: `Backends/CloudKit/Sync/ProfileDataSyncHandler+BatchUpsert.swift` — copy the three fields in the update branch of `batchUpsertInstruments`.
- Create: `MoolahTests/Domain/InstrumentRecordCryptoFieldsTests.swift` — schema + round-trip tests for the new fields.

- [ ] **Step 1: Write the failing tests**

Create `MoolahTests/Domain/InstrumentRecordCryptoFieldsTests.swift`:

```swift
import CloudKit
import Foundation
import Testing

@testable import Moolah

@Suite("InstrumentRecord — Crypto Provider Mapping Fields")
struct InstrumentRecordCryptoFieldsTests {
  @Test
  func initializerAcceptsAllMappingFields() {
    let record = InstrumentRecord(
      id: "1:native",
      kind: "cryptoToken",
      name: "Ethereum",
      decimals: 18,
      ticker: "ETH",
      exchange: nil,
      chainId: 1,
      contractAddress: nil,
      coingeckoId: "ethereum",
      cryptocompareSymbol: "ETH",
      binanceSymbol: "ETHUSDT"
    )
    #expect(record.coingeckoId == "ethereum")
    #expect(record.cryptocompareSymbol == "ETH")
    #expect(record.binanceSymbol == "ETHUSDT")
  }

  @Test
  func mappingFieldsDefaultToNil() {
    let record = InstrumentRecord(
      id: "AUD", kind: "fiatCurrency", name: "AUD", decimals: 2)
    #expect(record.coingeckoId == nil)
    #expect(record.cryptocompareSymbol == nil)
    #expect(record.binanceSymbol == nil)
  }

  @Test
  func ckRecordRoundTripWithMapping() {
    let original = InstrumentRecord(
      id: "1:0xdac17f958d2ee523a2206206994597c13d831ec7",
      kind: "cryptoToken",
      name: "Tether",
      decimals: 6,
      ticker: "USDT",
      chainId: 1,
      contractAddress: "0xdac17f958d2ee523a2206206994597c13d831ec7",
      coingeckoId: "tether",
      cryptocompareSymbol: "USDT",
      binanceSymbol: "USDTUSDT"
    )
    let zoneID = CKRecordZone.ID(zoneName: "test", ownerName: CKCurrentUserDefaultName)
    let ckRecord = original.toCKRecord(in: zoneID)

    #expect(ckRecord["coingeckoId"] as? String == "tether")
    #expect(ckRecord["cryptocompareSymbol"] as? String == "USDT")
    #expect(ckRecord["binanceSymbol"] as? String == "USDTUSDT")

    let decoded = InstrumentRecord.fieldValues(from: ckRecord)
    #expect(decoded.coingeckoId == "tether")
    #expect(decoded.cryptocompareSymbol == "USDT")
    #expect(decoded.binanceSymbol == "USDTUSDT")
  }

  @Test
  func ckRecordNilMappingFieldsAreAbsentNotNull() {
    let record = InstrumentRecord(
      id: "AUD", kind: "fiatCurrency", name: "AUD", decimals: 2)
    let zoneID = CKRecordZone.ID(zoneName: "test", ownerName: CKCurrentUserDefaultName)
    let ckRecord = record.toCKRecord(in: zoneID)

    #expect(ckRecord["coingeckoId"] == nil)
    #expect(ckRecord["cryptocompareSymbol"] == nil)
    #expect(ckRecord["binanceSymbol"] == nil)
    // Keys must not be present at all — saves record bytes and matches the
    // existing convention for ticker/exchange/chainId/contractAddress.
    #expect(ckRecord.allKeys().contains("coingeckoId") == false)
  }

  @Test
  func decodingPreMigrationCKRecordLeavesMappingFieldsNil() {
    // Simulate a record saved by an older version that didn't know about
    // the three new fields. Only the legacy keys are present.
    let zoneID = CKRecordZone.ID(zoneName: "test", ownerName: CKCurrentUserDefaultName)
    let recordID = CKRecord.ID(recordName: "AUD", zoneID: zoneID)
    let ckRecord = CKRecord(recordType: "CD_InstrumentRecord", recordID: recordID)
    ckRecord["kind"] = "fiatCurrency" as CKRecordValue
    ckRecord["name"] = "AUD" as CKRecordValue
    ckRecord["decimals"] = 2 as CKRecordValue

    let decoded = InstrumentRecord.fieldValues(from: ckRecord)
    #expect(decoded.coingeckoId == nil)
    #expect(decoded.cryptocompareSymbol == nil)
    #expect(decoded.binanceSymbol == nil)
    #expect(decoded.id == "AUD")
    #expect(decoded.kind == "fiatCurrency")
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
just generate    # InstrumentRecordCryptoFieldsTests.swift is new
just test InstrumentRecordCryptoFieldsTests 2>&1 | tee .agent-tmp/task2-pre.txt
```

Expected: compile error — `coingeckoId`, `cryptocompareSymbol`, `binanceSymbol` unknown.

- [ ] **Step 3: Extend the SwiftData model**

In `Backends/CloudKit/Models/InstrumentRecord.swift`, add three stored properties and extend the hand-written init:

```swift
@Model
final class InstrumentRecord {
  var id: String = ""
  var kind: String = "fiatCurrency"
  var name: String = ""
  var decimals: Int = 2
  var ticker: String?
  var exchange: String?
  var chainId: Int?
  var contractAddress: String?
  var coingeckoId: String?
  var cryptocompareSymbol: String?
  var binanceSymbol: String?
  var encodedSystemFields: Data?

  init(
    id: String,
    kind: String,
    name: String,
    decimals: Int,
    ticker: String? = nil,
    exchange: String? = nil,
    chainId: Int? = nil,
    contractAddress: String? = nil,
    coingeckoId: String? = nil,
    cryptocompareSymbol: String? = nil,
    binanceSymbol: String? = nil
  ) {
    self.id = id
    self.kind = kind
    self.name = name
    self.decimals = decimals
    self.ticker = ticker
    self.exchange = exchange
    self.chainId = chainId
    self.contractAddress = contractAddress
    self.coingeckoId = coingeckoId
    self.cryptocompareSymbol = cryptocompareSymbol
    self.binanceSymbol = binanceSymbol
  }

  func toDomain() -> Instrument {
    Instrument(
      id: id,
      kind: Instrument.Kind(rawValue: kind) ?? .fiatCurrency,
      name: name,
      decimals: decimals,
      ticker: ticker,
      exchange: exchange,
      chainId: chainId,
      contractAddress: contractAddress
    )
  }

  static func from(_ instrument: Instrument) -> InstrumentRecord {
    InstrumentRecord(
      id: instrument.id,
      kind: instrument.kind.rawValue,
      name: instrument.name,
      decimals: instrument.decimals,
      ticker: instrument.ticker,
      exchange: instrument.exchange,
      chainId: instrument.chainId,
      contractAddress: instrument.contractAddress
    )
  }
}
```

Note: `toDomain()` / `from(_:)` stay as-is because the `Instrument` domain type does not carry provider-mapping fields. Provider mappings travel alongside `Instrument` via `CryptoProviderMapping`.

- [ ] **Step 4: Extend the `CloudKitRecordConvertible` round-trip**

In `Backends/CloudKit/Sync/InstrumentRecord+CloudKit.swift`:

```swift
extension InstrumentRecord: CloudKitRecordConvertible {
  static let recordType = "CD_InstrumentRecord"

  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(recordName: id, zoneID: zoneID)
    let record = CKRecord(recordType: Self.recordType, recordID: recordID)
    record["kind"] = kind as CKRecordValue
    record["name"] = name as CKRecordValue
    record["decimals"] = decimals as CKRecordValue
    if let ticker { record["ticker"] = ticker as CKRecordValue }
    if let exchange { record["exchange"] = exchange as CKRecordValue }
    if let chainId { record["chainId"] = chainId as CKRecordValue }
    if let contractAddress { record["contractAddress"] = contractAddress as CKRecordValue }
    if let coingeckoId { record["coingeckoId"] = coingeckoId as CKRecordValue }
    if let cryptocompareSymbol {
      record["cryptocompareSymbol"] = cryptocompareSymbol as CKRecordValue
    }
    if let binanceSymbol { record["binanceSymbol"] = binanceSymbol as CKRecordValue }
    return record
  }

  static func fieldValues(from ckRecord: CKRecord) -> InstrumentRecord {
    InstrumentRecord(
      id: ckRecord.recordID.recordName,
      kind: ckRecord["kind"] as? String ?? "fiatCurrency",
      name: ckRecord["name"] as? String ?? "",
      decimals: ckRecord["decimals"] as? Int ?? 2,
      ticker: ckRecord["ticker"] as? String,
      exchange: ckRecord["exchange"] as? String,
      chainId: ckRecord["chainId"] as? Int,
      contractAddress: ckRecord["contractAddress"] as? String,
      coingeckoId: ckRecord["coingeckoId"] as? String,
      cryptocompareSymbol: ckRecord["cryptocompareSymbol"] as? String,
      binanceSymbol: ckRecord["binanceSymbol"] as? String
    )
  }
}
```

`as? String` returns `nil` for both a missing key and an explicit null, so pre-migration records decode safely without any force-cast.

- [ ] **Step 5: Extend `batchUpsertInstruments`**

In `Backends/CloudKit/Sync/ProfileDataSyncHandler+BatchUpsert.swift`, locate `batchUpsertInstruments` and add three lines to the update branch (where `existing.kind = values.kind` already lives):

```swift
existing.coingeckoId = values.coingeckoId
existing.cryptocompareSymbol = values.cryptocompareSymbol
existing.binanceSymbol = values.binanceSymbol
```

Without this, device B would decode the fields correctly from CloudKit but drop them on the copy-to-existing step for any row that already exists locally — a silent multi-device data-loss bug.

- [ ] **Step 6: Run tests**

```bash
just format
just generate
just test InstrumentRecordCryptoFieldsTests 2>&1 | tee .agent-tmp/task2-mid.txt
just test 2>&1 | tee .agent-tmp/task2-full.txt
```

Expected: all pass.

- [ ] **Step 7: Run sync + code review**

Run `@code-review` and `@sync-review` on the diff before committing. Address Critical / Major findings.

- [ ] **Step 8: Commit**

```bash
rm .agent-tmp/task2-*.txt
git add Backends/CloudKit/Models/InstrumentRecord.swift \
        Backends/CloudKit/Sync/InstrumentRecord+CloudKit.swift \
        Backends/CloudKit/Sync/ProfileDataSyncHandler+BatchUpsert.swift \
        MoolahTests/Domain/InstrumentRecordCryptoFieldsTests.swift
git commit -m "$(cat <<'EOF'
feat(sync): extend InstrumentRecord with crypto provider mapping fields

Adds coingeckoId / cryptocompareSymbol / binanceSymbol as nullable
optional fields on InstrumentRecord, extends CloudKitRecordConvertible
to round-trip them, and updates batchUpsertInstruments' field-copy to
avoid silently dropping them when syncing updates to an already-present
row on another device.

SwiftData's automatic lightweight migration handles the schema bump
(fields are optional with nil default). Pre-migration CKRecords decode
safely via as?-with-fallback.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Add `InstrumentRegistryRepository` protocol

**Files:**
- Create: `Domain/Repositories/InstrumentRegistryRepository.swift`

No tests yet — protocols without implementations aren't meaningfully testable in isolation. The contract test suite lands in Task 4.

- [ ] **Step 1: Create the protocol file**

```swift
// Domain/Repositories/InstrumentRegistryRepository.swift
import Foundation

/// The authoritative source of instruments visible to a CloudKit-backed
/// profile. Stock and crypto instruments are stored in the profile's
/// CloudKit-synced `InstrumentRecord` table; fiat instruments are ambient
/// and synthesized from `Locale.Currency.isoCurrencies`. Remote /
/// moolah-server profiles do not have a registry — they are single-instrument
/// by design.
protocol InstrumentRegistryRepository: Sendable {
  /// Every instrument visible to the profile: stock + crypto rows from the
  /// database, merged with the ambient fiat ISO list from
  /// `Locale.Currency.isoCurrencies`. De-duplicated by `Instrument.id`
  /// (stored row wins on collision with an ambient fiat entry).
  /// Throws on a backing-store failure (e.g. `ModelContainer` unavailable).
  func all() async throws -> [Instrument]

  /// All registered crypto instruments paired with their provider mappings.
  /// Rows whose three provider-mapping fields are all nil are skipped — they
  /// cannot be priced. (Such rows can arise from an auto-insert via
  /// `ensureInstrument` for a CSV-imported crypto position before the user
  /// has resolved its mapping.)
  /// Throws on a backing-store failure.
  func allCryptoRegistrations() async throws -> [CryptoRegistration]

  /// Registers (or upserts) a crypto instrument with its provider mapping.
  /// Re-registering an id that already exists overwrites the mapping and
  /// mutable metadata fields rather than duplicating the row. Invokes the
  /// implementation's sync-queue hook after a successful write.
  ///
  /// - Precondition: `instrument.kind == .cryptoToken`. Passing any other
  ///   kind is a programmer error and traps.
  func registerCrypto(
    _ instrument: Instrument, mapping: CryptoProviderMapping
  ) async throws

  /// Registers (or upserts) a stock instrument. Stock rows carry no
  /// provider-mapping fields; Yahoo's lookup key is the instrument's own
  /// ticker. Invokes the implementation's sync-queue hook after a
  /// successful write.
  ///
  /// - Precondition: `instrument.kind == .stock`. Passing any other
  ///   kind is a programmer error and traps.
  func registerStock(_ instrument: Instrument) async throws

  /// Removes a registered instrument by id. No-op for fiat ids and for
  /// ids that are not currently registered — does not throw. Invokes the
  /// implementation's sync-queue hook after a successful delete.
  func remove(instrumentId: String) async throws

  /// Creates a fresh change-observation stream for a single consumer.
  /// Every mutating call on this repository — `registerCrypto`,
  /// `registerStock`, `remove` — yields a `Void` to every outstanding
  /// stream created via this method. Terminating the returned stream
  /// (consumer cancellation or break) removes its continuation from the
  /// fan-out list.
  ///
  /// Scope: this stream fires only for *local* mutations. Remote-change
  /// notifications delivered by `CKSyncEngine` apply to `InstrumentRecord`
  /// via `batchUpsertInstruments` and do not fan out through this stream.
  /// Consumers that must react to remote changes also subscribe to the
  /// existing per-profile `SyncCoordinator` observer signal. Bridging the
  /// two signals is tracked in the follow-up UI issue.
  func observeChanges() -> AsyncStream<Void>
}
```

- [ ] **Step 2: Verify it compiles**

```bash
just generate
just build-mac 2>&1 | tee .agent-tmp/task3-build.txt
grep -iE 'error:' .agent-tmp/task3-build.txt | head -10
```

Expected: build succeeds. The protocol references `Instrument`, `CryptoProviderMapping`, and `CryptoRegistration`, all of which exist in Domain/Models/ — no import change needed (everything is in the same module).

- [ ] **Step 3: Commit**

```bash
just format
rm .agent-tmp/task3-*.txt
git add Domain/Repositories/InstrumentRegistryRepository.swift
git commit -m "$(cat <<'EOF'
feat(domain): add InstrumentRegistryRepository protocol

Defines the contract for the new per-profile instrument registry that
will replace CryptoTokenRepository / NSUbiquitousKeyValueStore. Split
register API (registerCrypto / registerStock) enforces the
"crypto-requires-mapping" invariant at the type level. observeChanges()
vends a fresh AsyncStream per consumer so multiple subscribers (UI
store, conversion closure, future picker) can coexist.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Implement `CloudKitInstrumentRegistryRepository`

The concrete implementation of the protocol from Task 3, with contract tests. Writes go through `mainContext`; reads go through a fresh background `ModelContext`. Sync-queue hooks inject from `CloudKitBackend` (wired up in Task 14). Multi-consumer change fan-out via a `@MainActor` dictionary of continuations.

**Files:**
- Create: `Backends/CloudKit/Repositories/CloudKitInstrumentRegistryRepository.swift`
- Create: `MoolahTests/Domain/InstrumentRegistryRepositoryContractTests.swift`

- [ ] **Step 1: Write the failing contract tests**

Create `MoolahTests/Domain/InstrumentRegistryRepositoryContractTests.swift`:

```swift
import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("InstrumentRegistryRepository — Contract")
@MainActor
struct InstrumentRegistryRepositoryContractTests {
  // Test fixture: builds an in-memory CloudKitInstrumentRegistryRepository
  // with captured sync-queue hooks, matching the public init signature.
  @MainActor
  final class HookCapture {
    var changedIds: [String] = []
    var deletedIds: [String] = []
  }

  @MainActor
  func makeSubject() -> (
    repo: CloudKitInstrumentRegistryRepository,
    hooks: HookCapture
  ) {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(
      for: InstrumentRecord.self,
      configurations: [config]
    )
    let hooks = HookCapture()
    let repo = CloudKitInstrumentRegistryRepository(
      modelContainer: container,
      onRecordChanged: { [hooks] id in Task { @MainActor in hooks.changedIds.append(id) } },
      onRecordDeleted: { [hooks] id in Task { @MainActor in hooks.deletedIds.append(id) } }
    )
    return (repo, hooks)
  }

  @Test("all() on a fresh profile returns every ISO currency and zero non-fiat rows")
  func freshProfileIsFiatOnly() async throws {
    let (repo, _) = makeSubject()
    let all = try await repo.all()
    let fiats = all.filter { $0.kind == .fiatCurrency }
    let nonFiats = all.filter { $0.kind != .fiatCurrency }
    #expect(fiats.count == Locale.Currency.isoCurrencies.count)
    #expect(nonFiats.isEmpty)
    #expect(all.contains { $0.id == "AUD" })
    #expect(all.contains { $0.id == "USD" })
  }

  @Test("registerStock makes the stock appear in all()")
  func registerStockAppears() async throws {
    let (repo, _) = makeSubject()
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    try await repo.registerStock(bhp)
    let all = try await repo.all()
    #expect(all.contains { $0.id == "ASX:BHP.AX" })
  }

  @Test("registerCrypto round-trips all eight crypto fields + three mapping fields")
  func registerCryptoRoundTrip() async throws {
    let (repo, _) = makeSubject()
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH",
      name: "Ethereum", decimals: 18)
    let mapping = CryptoProviderMapping(
      instrumentId: eth.id,
      coingeckoId: "ethereum",
      cryptocompareSymbol: "ETH",
      binanceSymbol: "ETHUSDT")
    try await repo.registerCrypto(eth, mapping: mapping)

    let regs = try await repo.allCryptoRegistrations()
    let reg = try #require(regs.first { $0.id == eth.id })
    #expect(reg.instrument.chainId == 1)
    #expect(reg.instrument.contractAddress == nil)
    #expect(reg.instrument.ticker == "ETH")
    #expect(reg.instrument.name == "Ethereum")
    #expect(reg.instrument.decimals == 18)
    #expect(reg.mapping.coingeckoId == "ethereum")
    #expect(reg.mapping.cryptocompareSymbol == "ETH")
    #expect(reg.mapping.binanceSymbol == "ETHUSDT")
  }

  @Test("registerCrypto with existing id upserts the mapping")
  func registerCryptoUpserts() async throws {
    let (repo, _) = makeSubject()
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH",
      name: "Ethereum", decimals: 18)
    let first = CryptoProviderMapping(
      instrumentId: eth.id,
      coingeckoId: "ethereum", cryptocompareSymbol: nil, binanceSymbol: nil)
    let second = CryptoProviderMapping(
      instrumentId: eth.id,
      coingeckoId: "ethereum", cryptocompareSymbol: "ETH", binanceSymbol: "ETHUSDT")
    try await repo.registerCrypto(eth, mapping: first)
    try await repo.registerCrypto(eth, mapping: second)

    let regs = try await repo.allCryptoRegistrations()
    #expect(regs.count == 1)
    #expect(regs.first?.mapping.cryptocompareSymbol == "ETH")
    #expect(regs.first?.mapping.binanceSymbol == "ETHUSDT")
  }

  @Test("allCryptoRegistrations skips rows whose three mapping fields are all nil")
  func allCryptoSkipsMissingMapping() async throws {
    let (repo, _) = makeSubject()
    // Simulate an ensureInstrument-auto-inserted row: crypto kind, but no
    // mapping fields.
    let container = (repo as Any as! CloudKitInstrumentRegistryRepository).modelContainer
    let context = container.mainContext
    let ghost = InstrumentRecord(
      id: "1:native",
      kind: "cryptoToken",
      name: "Ethereum",
      decimals: 18,
      ticker: "ETH",
      chainId: 1,
      contractAddress: nil
    )
    context.insert(ghost)
    try context.save()

    let regs = try await repo.allCryptoRegistrations()
    #expect(regs.isEmpty)
    // But it still appears in all() — it's a valid instrument, just unpriced.
    let all = try await repo.all()
    #expect(all.contains { $0.id == "1:native" && $0.kind == .cryptoToken })
  }

  @Test("remove deletes the row and is a no-op for fiat + unknown ids")
  func removeBehaviour() async throws {
    let (repo, _) = makeSubject()
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    try await repo.registerStock(bhp)

    try await repo.remove(instrumentId: bhp.id)
    let all = try await repo.all()
    #expect(all.contains { $0.id == bhp.id } == false)

    // No-op cases: must not throw.
    try await repo.remove(instrumentId: "AUD")                   // fiat id
    try await repo.remove(instrumentId: "DOES_NOT_EXIST:FOO")    // unknown id
  }

  @Test("sync-queue hook fires on registerStock / registerCrypto / remove")
  func syncHooksFire() async throws {
    let (repo, hooks) = makeSubject()
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    try await repo.registerStock(bhp)
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH",
      name: "Ethereum", decimals: 18)
    try await repo.registerCrypto(
      eth,
      mapping: CryptoProviderMapping(
        instrumentId: eth.id, coingeckoId: "ethereum",
        cryptocompareSymbol: nil, binanceSymbol: nil))
    try await repo.remove(instrumentId: bhp.id)

    // Give Task { @MainActor } hops a chance to drain.
    try await Task.sleep(for: .milliseconds(50))

    #expect(hooks.changedIds == ["ASX:BHP.AX", "1:native"])
    #expect(hooks.deletedIds == ["ASX:BHP.AX"])
  }

  @Test("sync-queue hook does not fire for fiat register or unknown remove")
  func syncHooksSkipNoops() async throws {
    let (repo, hooks) = makeSubject()
    // Fiat register is rejected by the type-level split — there is no
    // registerFiat. But unknown remove is a runtime no-op.
    try await repo.remove(instrumentId: "DOES_NOT_EXIST:FOO")
    try await Task.sleep(for: .milliseconds(50))
    #expect(hooks.changedIds.isEmpty)
    #expect(hooks.deletedIds.isEmpty)
  }

  @Test("observeChanges fans out to multiple consumers")
  func observeChangesFanOut() async throws {
    let (repo, _) = makeSubject()
    let streamA = repo.observeChanges()
    let streamB = repo.observeChanges()
    var iteratorA = streamA.makeAsyncIterator()
    var iteratorB = streamB.makeAsyncIterator()

    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    Task { try await repo.registerStock(bhp) }

    _ = await iteratorA.next()
    _ = await iteratorB.next()
    // If both iterators advanced we know both got a yield.
  }

  @Test("cancelled observeChanges consumer does not block sibling consumers")
  func observeChangesCancellation() async throws {
    let (repo, _) = makeSubject()
    let alive = repo.observeChanges()
    var aliveIterator = alive.makeAsyncIterator()

    let cancelTask = Task {
      var dropped = repo.observeChanges().makeAsyncIterator()
      _ = await dropped.next()
    }
    cancelTask.cancel()

    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    Task { try await repo.registerStock(bhp) }

    _ = await aliveIterator.next()   // would hang if the cancelled consumer
                                     // blocked the fan-out.
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
just generate
just test InstrumentRegistryRepositoryContractTests 2>&1 | tee .agent-tmp/task4-pre.txt
```

Expected: compile error — `CloudKitInstrumentRegistryRepository` not defined.

- [ ] **Step 3: Create the implementation**

Create `Backends/CloudKit/Repositories/CloudKitInstrumentRegistryRepository.swift`:

```swift
import Foundation
import OSLog
import SwiftData

final class CloudKitInstrumentRegistryRepository:
  InstrumentRegistryRepository, @unchecked Sendable
{
  let modelContainer: ModelContainer
  private let onRecordChanged: @Sendable (String) -> Void
  private let onRecordDeleted: @Sendable (String) -> Void
  private let logger = Logger(
    subsystem: "com.moolah.app", category: "InstrumentRegistry")

  @MainActor
  private var subscribers: [UUID: AsyncStream<Void>.Continuation] = [:]

  init(
    modelContainer: ModelContainer,
    onRecordChanged: @escaping @Sendable (String) -> Void = { _ in },
    onRecordDeleted: @escaping @Sendable (String) -> Void = { _ in }
  ) {
    self.modelContainer = modelContainer
    self.onRecordChanged = onRecordChanged
    self.onRecordDeleted = onRecordDeleted
  }

  // MARK: - Reads (background context)

  func all() async throws -> [Instrument] {
    let container = modelContainer
    return try await Task.detached(priority: .userInitiated) {
      let context = ModelContext(container)
      let descriptor = FetchDescriptor<InstrumentRecord>()
      let records = try context.fetch(descriptor)
      let stored = records.map { $0.toDomain() }
      let storedIds = Set(stored.map(\.id))
      let ambient = Locale.Currency.isoCurrencies
        .map(\.identifier)
        .map { Instrument.fiat(code: $0) }
        .filter { !storedIds.contains($0.id) }
      return stored + ambient
    }.value
  }

  func allCryptoRegistrations() async throws -> [CryptoRegistration] {
    let container = modelContainer
    return try await Task.detached(priority: .userInitiated) {
      let context = ModelContext(container)
      let descriptor = FetchDescriptor<InstrumentRecord>(
        predicate: #Predicate { $0.kind == "cryptoToken" }
      )
      let rows = try context.fetch(descriptor)
      return rows.compactMap { row -> CryptoRegistration? in
        let hasMapping =
          row.coingeckoId != nil
          || row.cryptocompareSymbol != nil
          || row.binanceSymbol != nil
        guard hasMapping else { return nil }
        let mapping = CryptoProviderMapping(
          instrumentId: row.id,
          coingeckoId: row.coingeckoId,
          cryptocompareSymbol: row.cryptocompareSymbol,
          binanceSymbol: row.binanceSymbol
        )
        return CryptoRegistration(instrument: row.toDomain(), mapping: mapping)
      }
    }.value
  }

  // MARK: - Writes (main context)

  func registerCrypto(
    _ instrument: Instrument, mapping: CryptoProviderMapping
  ) async throws {
    precondition(instrument.kind == .cryptoToken)
    let container = modelContainer
    try await MainActor.run {
      let context = container.mainContext
      let id = instrument.id
      let descriptor = FetchDescriptor<InstrumentRecord>(
        predicate: #Predicate { $0.id == id }
      )
      if let existing = try context.fetch(descriptor).first {
        existing.kind = instrument.kind.rawValue
        existing.name = instrument.name
        existing.decimals = instrument.decimals
        existing.ticker = instrument.ticker
        existing.exchange = instrument.exchange
        existing.chainId = instrument.chainId
        existing.contractAddress = instrument.contractAddress
        existing.coingeckoId = mapping.coingeckoId
        existing.cryptocompareSymbol = mapping.cryptocompareSymbol
        existing.binanceSymbol = mapping.binanceSymbol
      } else {
        let row = InstrumentRecord(
          id: id,
          kind: instrument.kind.rawValue,
          name: instrument.name,
          decimals: instrument.decimals,
          ticker: instrument.ticker,
          exchange: instrument.exchange,
          chainId: instrument.chainId,
          contractAddress: instrument.contractAddress,
          coingeckoId: mapping.coingeckoId,
          cryptocompareSymbol: mapping.cryptocompareSymbol,
          binanceSymbol: mapping.binanceSymbol
        )
        context.insert(row)
      }
      try context.save()
    }
    onRecordChanged(instrument.id)
    await notifySubscribers()
  }

  func registerStock(_ instrument: Instrument) async throws {
    precondition(instrument.kind == .stock)
    let container = modelContainer
    try await MainActor.run {
      let context = container.mainContext
      let id = instrument.id
      let descriptor = FetchDescriptor<InstrumentRecord>(
        predicate: #Predicate { $0.id == id }
      )
      if let existing = try context.fetch(descriptor).first {
        existing.kind = instrument.kind.rawValue
        existing.name = instrument.name
        existing.decimals = instrument.decimals
        existing.ticker = instrument.ticker
        existing.exchange = instrument.exchange
      } else {
        let row = InstrumentRecord(
          id: id,
          kind: instrument.kind.rawValue,
          name: instrument.name,
          decimals: instrument.decimals,
          ticker: instrument.ticker,
          exchange: instrument.exchange
        )
        context.insert(row)
      }
      try context.save()
    }
    onRecordChanged(instrument.id)
    await notifySubscribers()
  }

  func remove(instrumentId: String) async throws {
    let container = modelContainer
    let didDelete: Bool = try await MainActor.run {
      let context = container.mainContext
      let descriptor = FetchDescriptor<InstrumentRecord>(
        predicate: #Predicate { $0.id == instrumentId }
      )
      guard let existing = try context.fetch(descriptor).first else { return false }
      guard existing.kind != Instrument.Kind.fiatCurrency.rawValue else { return false }
      context.delete(existing)
      try context.save()
      return true
    }
    guard didDelete else { return }
    onRecordDeleted(instrumentId)
    await notifySubscribers()
  }

  // MARK: - Change fan-out

  func observeChanges() -> AsyncStream<Void> {
    AsyncStream { [weak self] continuation in
      guard let self else {
        continuation.finish()
        return
      }
      let key = UUID()
      Task { @MainActor in self.subscribers[key] = continuation }
      continuation.onTermination = { @Sendable [weak self] _ in
        guard let self else { return }
        Task { @MainActor in self.subscribers[key] = nil }
      }
    }
  }

  @MainActor
  private func notifySubscribers() {
    for continuation in subscribers.values {
      continuation.yield()
    }
  }
}
```

- [ ] **Step 4: Run tests**

```bash
just format
just generate
just test InstrumentRegistryRepositoryContractTests 2>&1 | tee .agent-tmp/task4-mid.txt
```

Expected: all pass.

- [ ] **Step 5: Run concurrency + code review**

Run `@concurrency-review` and `@code-review` on this diff. The `@unchecked Sendable` + `@MainActor`-confined subscribers dictionary is the pattern in focus; address any findings.

- [ ] **Step 6: Run the full test suite**

```bash
just test 2>&1 | tee .agent-tmp/task4-full.txt
grep -iE 'failed|error:' .agent-tmp/task4-full.txt | head -20
```

Expected: clean.

- [ ] **Step 7: Commit**

```bash
rm .agent-tmp/task4-*.txt
git add Backends/CloudKit/Repositories/CloudKitInstrumentRegistryRepository.swift \
        MoolahTests/Domain/InstrumentRegistryRepositoryContractTests.swift
git commit -m "$(cat <<'EOF'
feat(backends): implement CloudKitInstrumentRegistryRepository

Concrete implementation of InstrumentRegistryRepository. Reads run on
a fresh background ModelContext; writes run on the mainContext to
match the existing CloudKitAccountRepository / CloudKitTransactionRepository
pattern. Multi-consumer change fan-out via a @MainActor-confined
dictionary of AsyncStream continuations. Sync-queue hooks injected
so writes upload through the existing SyncCoordinator path (wired
up in Task 14).

Contract tests cover the full surface including error paths, auto-
inserted crypto rows without mappings, and fan-out cancellation.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Add `purgeCache(instrumentId:)` to `CryptoPriceService`

Additive change to prepare for the `CryptoTokenStore` rewire in Task 13. No callers yet.

**Files:**
- Modify: `Shared/CryptoPriceService.swift` — add the method.
- Modify: `MoolahTests/Shared/CryptoPriceServiceTests.swift` (or a new test file if that file is already at SwiftLint's file-length limit) — add tests for the new method.

- [ ] **Step 1: Write the failing test**

Append to `MoolahTests/Shared/CryptoPriceServiceTests.swift` (or create a small companion if the file is too long):

```swift
@Test("purgeCache removes the in-memory cache entry and disk file")
func purgeCacheRemovesInMemoryAndDisk() async throws {
  let tempDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("purge-test-\(UUID())")
  try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: tempDir) }

  let stub = StubCryptoPriceClient(  // whatever stub is used elsewhere in the file
    prices: ["ethereum": 2500]
  )
  let service = CryptoPriceService(
    clients: [stub],
    cacheDirectory: tempDir,
    resolutionClient: NoOpTokenResolutionClient()
  )

  let eth = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "ETH",
    name: "Ethereum", decimals: 18)
  let mapping = CryptoProviderMapping(
    instrumentId: eth.id, coingeckoId: "ethereum",
    cryptocompareSymbol: nil, binanceSymbol: nil)

  _ = try await service.price(for: eth, mapping: mapping, on: Date())
  let filename = "prices-\(eth.id.replacingOccurrences(of: ":", with: "-")).json.gz"
  let onDisk = tempDir.appendingPathComponent(filename)
  #expect(FileManager.default.fileExists(atPath: onDisk.path))

  await service.purgeCache(instrumentId: eth.id)
  #expect(FileManager.default.fileExists(atPath: onDisk.path) == false)
}
```

(Use the pre-existing stub pattern already present in `CryptoPriceServiceTests.swift` — copy its `StubCryptoPriceClient` / `NoOpTokenResolutionClient` idioms; don't invent new ones.)

- [ ] **Step 2: Run test to verify it fails**

```bash
just test CryptoPriceServiceTests 2>&1 | tee .agent-tmp/task5-pre.txt
```

Expected: compile error — `purgeCache` unknown.

- [ ] **Step 3: Add the method**

In `Shared/CryptoPriceService.swift`, add a method inside the actor (after `removeById(_:)`):

```swift
/// Drops any cached price data for the given instrument id — removes
/// both the in-memory cache entry and the on-disk cache file. Called
/// when an instrument is un-registered so we don't retain stale prices
/// for something the user no longer cares about.
func purgeCache(instrumentId: String) {
  caches.removeValue(forKey: instrumentId)
  let url = cacheFileURL(tokenId: instrumentId)
  try? FileManager.default.removeItem(at: url)
}
```

- [ ] **Step 4: Run test**

```bash
just format
just test CryptoPriceServiceTests 2>&1 | tee .agent-tmp/task5-mid.txt
```

Expected: pass.

- [ ] **Step 5: Commit**

```bash
rm .agent-tmp/task5-*.txt
git add Shared/CryptoPriceService.swift MoolahTests/Shared/CryptoPriceServiceTests.swift
git commit -m "$(cat <<'EOF'
feat(shared): add CryptoPriceService.purgeCache(instrumentId:)

Additive. Allows a caller to drop cached price data for an un-registered
instrument without reaching into the service's private cache layer.
Used by the upcoming CryptoTokenStore rewire to clear price data on
removeRegistration.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Add `CryptoSearchClient` protocol + `CoinGeckoSearchClient`

**Files:**
- Create: `Domain/Repositories/CryptoSearchClient.swift` — protocol + `CryptoSearchHit` value type.
- Create: `Backends/CoinGecko/CoinGeckoSearchClient.swift` — default implementation.
- Create: `MoolahTests/Backends/CoinGeckoSearchClientTests.swift` — URLProtocol-stubbed round-trip test.
- Create: `MoolahTests/Support/Fixtures/coingecko-search-bitcoin.json` — response fixture.

- [ ] **Step 1: Write the failing tests**

`MoolahTests/Backends/CoinGeckoSearchClientTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("CoinGeckoSearchClient")
struct CoinGeckoSearchClientTests {
  @Test
  func searchReturnsHitsFromFixture() async throws {
    let fixture = Bundle(for: FixtureLoader.self)
      .url(forResource: "coingecko-search-bitcoin", withExtension: "json")!
    let data = try Data(contentsOf: fixture)
    let session = URLSession(
      configuration: .stubbed(responseBody: data, statusCode: 200)
    )
    let client = CoinGeckoSearchClient(apiKey: nil, session: session)
    let hits = try await client.search(query: "bitcoin")
    #expect(hits.count > 0)
    #expect(hits.first?.coingeckoId == "bitcoin")
    #expect(hits.first?.symbol == "BTC")
  }

  @Test
  func searchThrowsOnErrorStatus() async throws {
    let session = URLSession(
      configuration: .stubbed(responseBody: Data(), statusCode: 500)
    )
    let client = CoinGeckoSearchClient(apiKey: nil, session: session)
    await #expect(throws: Error.self) {
      _ = try await client.search(query: "x")
    }
  }
}
```

(`FixtureLoader` and `URLSessionConfiguration.stubbed(...)` are project idioms used by the other `*ClientTests`; reuse rather than reinvent.)

Fixture `MoolahTests/Support/Fixtures/coingecko-search-bitcoin.json`:

```json
{
  "coins": [
    { "id": "bitcoin", "name": "Bitcoin", "symbol": "BTC", "thumb": "https://x/bitcoin.png" },
    { "id": "wrapped-bitcoin", "name": "Wrapped Bitcoin", "symbol": "WBTC", "thumb": "" }
  ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
just generate
just test CoinGeckoSearchClientTests 2>&1 | tee .agent-tmp/task6-pre.txt
```

Expected: compile error — types undefined.

- [ ] **Step 3: Create the protocol**

`Domain/Repositories/CryptoSearchClient.swift`:

```swift
import Foundation

/// A hit from a crypto-token search provider. Does not yet include
/// chain / contract / decimals — callers that want to persist the hit
/// must subsequently resolve those via `TokenResolutionClient`.
struct CryptoSearchHit: Sendable, Hashable {
  let coingeckoId: String
  let symbol: String
  let name: String
  let thumbnail: URL?
}

/// Abstract search service for crypto tokens, typically backed by
/// CoinGecko's `/search` endpoint.
protocol CryptoSearchClient: Sendable {
  func search(query: String) async throws -> [CryptoSearchHit]
}
```

- [ ] **Step 4: Create the implementation**

`Backends/CoinGecko/CoinGeckoSearchClient.swift`:

```swift
import Foundation

struct CoinGeckoSearchClient: CryptoSearchClient {
  private let apiKey: String?
  private let session: URLSession
  private static let baseURL = URL(string: "https://api.coingecko.com/api/v3")!

  init(apiKey: String? = nil, session: URLSession = .shared) {
    self.apiKey = apiKey
    self.session = session
  }

  func search(query: String) async throws -> [CryptoSearchHit] {
    var components = URLComponents(
      url: Self.baseURL.appendingPathComponent("search"),
      resolvingAgainstBaseURL: false
    )!
    components.queryItems = [URLQueryItem(name: "query", value: query)]
    var request = URLRequest(url: components.url!)
    if let apiKey { request.setValue(apiKey, forHTTPHeaderField: "x-cg-demo-api-key") }
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse,
      (200..<300).contains(http.statusCode)
    else {
      throw URLError(.badServerResponse)
    }
    let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
    return decoded.coins.map { coin in
      CryptoSearchHit(
        coingeckoId: coin.id,
        symbol: coin.symbol.uppercased(),
        name: coin.name,
        thumbnail: URL(string: coin.thumb ?? "")
      )
    }
  }

  private struct SearchResponse: Decodable {
    let coins: [Coin]
    struct Coin: Decodable {
      let id: String
      let name: String
      let symbol: String
      let thumb: String?
    }
  }
}
```

- [ ] **Step 5: Run tests**

```bash
just format
just generate
just test CoinGeckoSearchClientTests 2>&1 | tee .agent-tmp/task6-mid.txt
```

Expected: all pass.

- [ ] **Step 6: Commit**

```bash
rm .agent-tmp/task6-*.txt
git add Domain/Repositories/CryptoSearchClient.swift \
        Backends/CoinGecko/CoinGeckoSearchClient.swift \
        MoolahTests/Backends/CoinGeckoSearchClientTests.swift \
        MoolahTests/Support/Fixtures/coingecko-search-bitcoin.json
git commit -m "$(cat <<'EOF'
feat(backends): add CryptoSearchClient + CoinGeckoSearchClient

Thin search-side wrapper over CoinGecko's /search endpoint. Returns
CryptoSearchHit values that the upcoming InstrumentSearchService
will merge with fiat/stock results. Hits carry only the CoinGecko id
+ symbol + name — chainId / contractAddress / decimals are intentionally
deferred to TokenResolutionClient at registration time.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Add `StockTickerValidator` protocol + Yahoo-backed implementation

**Files:**
- Create: `Domain/Repositories/StockTickerValidator.swift` — protocol + a small `ValidatedStockTicker` value type.
- Create: `Backends/YahooFinance/YahooFinanceStockTickerValidator.swift` — default implementation using `YahooFinanceClient`.
- Create: `MoolahTests/Backends/YahooFinanceStockTickerValidatorTests.swift`.

- [ ] **Step 1: Write the failing tests**

`MoolahTests/Backends/YahooFinanceStockTickerValidatorTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("YahooFinanceStockTickerValidator")
struct YahooFinanceStockTickerValidatorTests {
  @Test("parses EXCHANGE:TICKER form")
  func parsesExchangeTickerForm() async throws {
    let stub = StubYahooFinancePriceFetcher(available: ["BHP.AX": 45.0])
    let validator = YahooFinanceStockTickerValidator(priceFetcher: stub)
    let result = try await validator.validate(query: "ASX:BHP.AX")
    #expect(result?.ticker == "BHP.AX")
    #expect(result?.exchange == "ASX")
  }

  @Test("parses Yahoo-native suffix form")
  func parsesYahooSuffixForm() async throws {
    let stub = StubYahooFinancePriceFetcher(available: ["BHP.AX": 45.0])
    let validator = YahooFinanceStockTickerValidator(priceFetcher: stub)
    let result = try await validator.validate(query: "BHP.AX")
    #expect(result?.ticker == "BHP.AX")
    #expect(result?.exchange == "ASX")
  }

  @Test("returns nil when price fetcher finds nothing")
  func returnsNilWhenUnknown() async throws {
    let stub = StubYahooFinancePriceFetcher(available: [:])
    let validator = YahooFinanceStockTickerValidator(priceFetcher: stub)
    let result = try await validator.validate(query: "UNKNOWN")
    #expect(result == nil)
  }

  @Test("bare ticker without Yahoo suffix defaults to NASDAQ")
  func bareTickerDefaultsToNasdaq() async throws {
    let stub = StubYahooFinancePriceFetcher(available: ["AAPL": 180.0])
    let validator = YahooFinanceStockTickerValidator(priceFetcher: stub)
    let result = try await validator.validate(query: "AAPL")
    #expect(result?.ticker == "AAPL")
    #expect(result?.exchange == "NASDAQ")
  }
}

private struct StubYahooFinancePriceFetcher: YahooFinancePriceFetcher {
  let available: [String: Double]
  func currentPrice(for ticker: String) async throws -> Decimal? {
    guard let price = available[ticker] else { return nil }
    return Decimal(price)
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
just generate
just test YahooFinanceStockTickerValidatorTests 2>&1 | tee .agent-tmp/task7-pre.txt
```

Expected: compile error — types undefined.

- [ ] **Step 3: Create the protocol and value type**

`Domain/Repositories/StockTickerValidator.swift`:

```swift
import Foundation

struct ValidatedStockTicker: Sendable, Hashable {
  let ticker: String
  let exchange: String
}

protocol StockTickerValidator: Sendable {
  /// Attempts to validate a typed stock-ticker query. Accepts two forms:
  /// - `"EXCHANGE:TICKER"` — the canonical id form used throughout the
  ///   registry (e.g. `"ASX:BHP.AX"`).
  /// - Yahoo-native suffixed ticker — e.g. `"BHP.AX"`, `"AAPL"`,
  ///   `"^GSPC"`. The validator normalises both forms to an
  ///   `(exchange, ticker)` pair before fetching a probe price.
  /// Returns nil when no price is available for the parsed ticker.
  func validate(query: String) async throws -> ValidatedStockTicker?
}
```

- [ ] **Step 4: Extract a seam on `YahooFinanceClient` for injection**

Add a minimal `YahooFinancePriceFetcher` protocol inside `Backends/YahooFinance/` that `YahooFinanceClient` conforms to — just the single-ticker current-price method the validator needs. This avoids bringing the full `StockPriceClient` surface into the validator's dependency graph. Example:

```swift
// Backends/YahooFinance/YahooFinancePriceFetcher.swift
protocol YahooFinancePriceFetcher: Sendable {
  func currentPrice(for ticker: String) async throws -> Decimal?
}

extension YahooFinanceClient: YahooFinancePriceFetcher {
  // Use the existing price-fetch method on YahooFinanceClient; if the
  // nearest existing method returns multiple values, adapt it to return
  // the single price here. Keep the adaptation in the extension so the
  // client's primary surface is untouched.
}
```

Inspect `Backends/YahooFinance/YahooFinanceClient.swift` to find the closest existing single-ticker method and adapt.

- [ ] **Step 5: Create the validator implementation**

`Backends/YahooFinance/YahooFinanceStockTickerValidator.swift`:

```swift
import Foundation

struct YahooFinanceStockTickerValidator: StockTickerValidator {
  private let priceFetcher: any YahooFinancePriceFetcher

  init(priceFetcher: any YahooFinancePriceFetcher) {
    self.priceFetcher = priceFetcher
  }

  func validate(query: String) async throws -> ValidatedStockTicker? {
    guard let parsed = parse(query: query) else { return nil }
    let price = try await priceFetcher.currentPrice(for: parsed.ticker)
    guard price != nil else { return nil }
    return parsed
  }

  private func parse(query: String) -> ValidatedStockTicker? {
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }

    if trimmed.contains(":") {
      let parts = trimmed.split(separator: ":", maxSplits: 1)
      guard parts.count == 2 else { return nil }
      return ValidatedStockTicker(
        ticker: String(parts[1]),
        exchange: String(parts[0]).uppercased())
    }

    if trimmed.contains(".") {
      let parts = trimmed.split(separator: ".", maxSplits: 1)
      guard parts.count == 2 else { return nil }
      let exchange = Self.yahooSuffixToExchange(String(parts[1]))
      return ValidatedStockTicker(ticker: trimmed, exchange: exchange)
    }

    // Bare ticker — default to NASDAQ.
    return ValidatedStockTicker(ticker: trimmed.uppercased(), exchange: "NASDAQ")
  }

  private static func yahooSuffixToExchange(_ suffix: String) -> String {
    switch suffix.uppercased() {
    case "AX": "ASX"
    case "L": "LSE"
    case "TO": "TSX"
    case "HK": "HKEX"
    case "T": "TYO"
    case "PA": "EPA"
    case "DE": "FRA"
    default: suffix.uppercased()
    }
  }
}
```

- [ ] **Step 6: Run tests**

```bash
just format
just generate
just test YahooFinanceStockTickerValidatorTests 2>&1 | tee .agent-tmp/task7-mid.txt
```

Expected: all pass.

- [ ] **Step 7: Commit**

```bash
rm .agent-tmp/task7-*.txt
git add Domain/Repositories/StockTickerValidator.swift \
        Backends/YahooFinance/YahooFinancePriceFetcher.swift \
        Backends/YahooFinance/YahooFinanceStockTickerValidator.swift \
        MoolahTests/Backends/YahooFinanceStockTickerValidatorTests.swift
git commit -m "$(cat <<'EOF'
feat(backends): add StockTickerValidator + Yahoo implementation

Validates typed stock-ticker queries for the InstrumentSearchService.
Accepts both EXCHANGE:TICKER and Yahoo-native suffixed forms; maps
common suffixes (.AX -> ASX, .L -> LSE, .TO -> TSX, etc). Returns nil
when no price is available for the parsed ticker.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: `InstrumentSearchResult` + `InstrumentSearchService`

**Files:**
- Create: `Shared/InstrumentSearchResult.swift` — value type + custom Equatable/Hashable keyed on id.
- Create: `Shared/InstrumentSearchService.swift` — stateless struct with fan-out search.
- Create: `MoolahTests/Shared/InstrumentSearchServiceTests.swift`.

- [ ] **Step 1: Write the failing tests**

`MoolahTests/Shared/InstrumentSearchServiceTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("InstrumentSearchService")
@MainActor
struct InstrumentSearchServiceTests {
  @MainActor
  func makeSubject(
    registered: [Instrument] = [],
    cryptoHits: [CryptoSearchHit] = [],
    cryptoSearchThrows: Bool = false,
    stockValidated: ValidatedStockTicker? = nil,
    stockValidatorThrows: Bool = false,
    resolvedRegistration: CryptoRegistration? = nil
  ) -> InstrumentSearchService {
    let registry = StubRegistry(instruments: registered)
    let crypto = StubCryptoSearchClient(hits: cryptoHits, shouldThrow: cryptoSearchThrows)
    let stock = StubStockTickerValidator(
      validated: stockValidated, shouldThrow: stockValidatorThrows)
    let resolver = StubTokenResolutionClient(resolved: resolvedRegistration)
    return InstrumentSearchService(
      registry: registry,
      cryptoSearchClient: crypto,
      resolutionClient: resolver,
      stockValidator: stock
    )
  }

  @Test("fiat prefix match on ISO code")
  func fiatPrefixMatch() async {
    let service = makeSubject()
    let results = await service.search(query: "usd")
    #expect(results.contains { $0.instrument.id == "USD" })
    #expect(results.allSatisfy { $0.instrument.kind == .fiatCurrency })
  }

  @Test("fiat substring match on localized name")
  func fiatNameMatch() async {
    let service = makeSubject()
    let results = await service.search(query: "dollar")
    // At minimum USD and AUD should surface; asserting "at least one" keeps
    // the test robust against locale variation.
    let ids = results.map(\.instrument.id)
    #expect(ids.contains("USD") || ids.contains("AUD"))
  }

  @Test("crypto hits marked requiresResolution = true with populated coingeckoId")
  func cryptoHitsMarkedForResolution() async {
    let hits = [
      CryptoSearchHit(
        coingeckoId: "bitcoin", symbol: "BTC", name: "Bitcoin", thumbnail: nil),
      CryptoSearchHit(
        coingeckoId: "ethereum", symbol: "ETH", name: "Ethereum", thumbnail: nil),
    ]
    let service = makeSubject(cryptoHits: hits)
    let results = await service.search(query: "bitcoin", kinds: [.cryptoToken])
    #expect(results.contains { $0.instrument.ticker == "BTC" && $0.requiresResolution })
    #expect(
      results.first {
        $0.cryptoMapping?.coingeckoId == "bitcoin"
      } != nil
    )
  }

  @Test("crypto query matching contract-address pattern bypasses search and calls resolver")
  func contractAddressBypassesSearch() async {
    let eth = Instrument.crypto(
      chainId: 1,
      contractAddress: "0xdac17f958d2ee523a2206206994597c13d831ec7",
      symbol: "USDT", name: "Tether", decimals: 6)
    let mapping = CryptoProviderMapping(
      instrumentId: eth.id,
      coingeckoId: "tether",
      cryptocompareSymbol: "USDT",
      binanceSymbol: "USDTUSDT")
    let service = makeSubject(
      cryptoHits: [],   // would cause the test to fail if the search path was used
      resolvedRegistration: CryptoRegistration(instrument: eth, mapping: mapping)
    )
    let results = await service.search(
      query: "0xdAC17F958D2ee523a2206206994597C13D831ec7", kinds: [.cryptoToken])
    #expect(results.count == 1)
    #expect(results.first?.requiresResolution == false)
    #expect(results.first?.cryptoMapping?.cryptocompareSymbol == "USDT")
  }

  @Test("valid typed stock ticker yields one result")
  func stockValidTypedTicker() async {
    let validated = ValidatedStockTicker(ticker: "BHP.AX", exchange: "ASX")
    let service = makeSubject(stockValidated: validated)
    let results = await service.search(query: "BHP.AX", kinds: [.stock])
    #expect(results.count == 1)
    #expect(results.first?.instrument.id == "ASX:BHP.AX")
    #expect(results.first?.requiresResolution == false)
  }

  @Test("invalid stock ticker yields no stock results")
  func stockInvalidTicker() async {
    let service = makeSubject(stockValidated: nil)
    let results = await service.search(query: "UNKNOWN", kinds: [.stock])
    #expect(results.isEmpty)
  }

  @Test("stock validator throw is absorbed; other kinds still return")
  func stockValidatorThrowAbsorbed() async {
    let service = makeSubject(stockValidatorThrows: true)
    let results = await service.search(query: "usd")
    // Fiat results still surface.
    #expect(results.contains { $0.instrument.id == "USD" })
  }

  @Test("registered instruments marked isRegistered = true and ranked first")
  func registeredRankFirst() async {
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let service = makeSubject(registered: [bhp])
    let results = await service.search(query: "BHP", kinds: [.stock])
    let bhpResult = try? #require(results.first { $0.instrument.id == "ASX:BHP.AX" })
    #expect(bhpResult?.isRegistered == true)
    // It appears before any non-registered stock result.
    let idx = results.firstIndex { $0.instrument.id == "ASX:BHP.AX" } ?? 0
    let otherStockIdx = results.firstIndex {
      $0.instrument.kind == .stock && !$0.isRegistered
    } ?? Int.max
    #expect(idx < otherStockIdx)
  }

  @Test("provider hit sharing an id with a registered entry is dropped")
  func dedupePreferRegistered() async {
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH",
      name: "Ethereum", decimals: 18)
    // registered ETH exists; crypto search hit also claims ETH (same id).
    let hit = CryptoSearchHit(
      coingeckoId: "ethereum", symbol: "ETH", name: "Ethereum", thumbnail: nil)
    let service = makeSubject(registered: [eth], cryptoHits: [hit])
    let results = await service.search(query: "ETH", kinds: [.cryptoToken])
    let matching = results.filter { $0.instrument.id == eth.id }
    #expect(matching.count == 1)
    #expect(matching.first?.isRegistered == true)
  }

  @Test("empty query returns the registered set")
  func emptyQueryReturnsRegistered() async {
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let service = makeSubject(registered: [bhp])
    let results = await service.search(query: "")
    #expect(results.contains { $0.instrument.id == "ASX:BHP.AX" })
    #expect(results.allSatisfy(\.isRegistered))
  }
}

// MARK: - Stubs

private struct StubRegistry: InstrumentRegistryRepository, @unchecked Sendable {
  let instruments: [Instrument]
  func all() async throws -> [Instrument] { instruments }
  func allCryptoRegistrations() async throws -> [CryptoRegistration] { [] }
  func registerCrypto(
    _ instrument: Instrument, mapping: CryptoProviderMapping
  ) async throws {}
  func registerStock(_ instrument: Instrument) async throws {}
  func remove(instrumentId: String) async throws {}
  func observeChanges() -> AsyncStream<Void> { AsyncStream { _ in } }
}

private struct StubCryptoSearchClient: CryptoSearchClient {
  let hits: [CryptoSearchHit]
  let shouldThrow: Bool
  func search(query: String) async throws -> [CryptoSearchHit] {
    if shouldThrow { throw URLError(.cannotConnectToHost) }
    return hits
  }
}

private struct StubStockTickerValidator: StockTickerValidator {
  let validated: ValidatedStockTicker?
  let shouldThrow: Bool
  func validate(query: String) async throws -> ValidatedStockTicker? {
    if shouldThrow { throw URLError(.cannotConnectToHost) }
    return validated
  }
}

private struct StubTokenResolutionClient: TokenResolutionClient {
  let resolved: CryptoRegistration?
  func resolve(
    chainId: Int, contractAddress: String?, symbol: String?, isNative: Bool
  ) async throws -> TokenResolutionResult {
    guard let resolved else { return TokenResolutionResult() }
    return TokenResolutionResult(
      coingeckoId: resolved.mapping.coingeckoId,
      cryptocompareSymbol: resolved.mapping.cryptocompareSymbol,
      binanceSymbol: resolved.mapping.binanceSymbol,
      resolvedSymbol: resolved.instrument.ticker,
      resolvedName: resolved.instrument.name,
      resolvedDecimals: resolved.instrument.decimals
    )
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
just generate
just test InstrumentSearchServiceTests 2>&1 | tee .agent-tmp/task8-pre.txt
```

Expected: compile error — `InstrumentSearchService`, `InstrumentSearchResult` undefined.

- [ ] **Step 3: Create `InstrumentSearchResult`**

`Shared/InstrumentSearchResult.swift`:

```swift
import Foundation

/// One candidate returned by `InstrumentSearchService`. May represent an
/// already-registered instrument (pulled from `InstrumentRegistryRepository`),
/// a crypto provider hit that still needs resolution before it can be
/// persisted, a validated stock ticker, or an ambient fiat currency.
struct InstrumentSearchResult: Sendable, Identifiable {
  let instrument: Instrument
  let cryptoMapping: CryptoProviderMapping?
  let isRegistered: Bool
  let requiresResolution: Bool

  var id: String { instrument.id }
}

extension InstrumentSearchResult: Equatable {
  static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

extension InstrumentSearchResult: Hashable {
  func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
```

- [ ] **Step 4: Create `InstrumentSearchService`**

`Shared/InstrumentSearchService.swift`:

```swift
import Foundation
import OSLog

struct InstrumentSearchService: Sendable {
  private let registry: any InstrumentRegistryRepository
  private let cryptoSearchClient: any CryptoSearchClient
  private let resolutionClient: any TokenResolutionClient
  private let stockValidator: any StockTickerValidator
  private let logger = Logger(
    subsystem: "com.moolah.app", category: "InstrumentSearch")

  private static let contractAddressPattern = try! NSRegularExpression(
    pattern: "^0x[0-9a-fA-F]{40}$"
  )

  init(
    registry: any InstrumentRegistryRepository,
    cryptoSearchClient: any CryptoSearchClient,
    resolutionClient: any TokenResolutionClient,
    stockValidator: any StockTickerValidator
  ) {
    self.registry = registry
    self.cryptoSearchClient = cryptoSearchClient
    self.resolutionClient = resolutionClient
    self.stockValidator = stockValidator
  }

  func search(
    query: String, kinds: Set<Instrument.Kind>? = nil
  ) async -> [InstrumentSearchResult] {
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    let registered = (try? await registry.all()) ?? []
    if trimmed.isEmpty {
      return registered.map {
        InstrumentSearchResult(
          instrument: $0, cryptoMapping: nil,
          isRegistered: true, requiresResolution: false)
      }
    }

    let wantedKinds = kinds ?? Set(Instrument.Kind.allCases)

    async let fiatResults: [InstrumentSearchResult] =
      wantedKinds.contains(.fiatCurrency)
      ? fiatMatches(query: trimmed) : []
    async let cryptoResults: [InstrumentSearchResult] =
      wantedKinds.contains(.cryptoToken)
      ? cryptoMatches(query: trimmed) : []
    async let stockResults: [InstrumentSearchResult] =
      wantedKinds.contains(.stock)
      ? stockMatches(query: trimmed) : []

    let provider = await (fiatResults + cryptoResults + stockResults)
    let registeredMatches = registeredMatches(query: trimmed, all: registered)
    return merge(registered: registeredMatches, provider: provider)
  }

  // MARK: - Fiat

  private func fiatMatches(query: String) -> [InstrumentSearchResult] {
    let lowered = query.lowercased()
    return Locale.Currency.isoCurrencies.compactMap { currency in
      let code = currency.identifier
      let lowerCode = code.lowercased()
      let localizedName = Locale.current.localizedString(
        forCurrencyCode: code)?.lowercased() ?? ""
      guard lowerCode.hasPrefix(lowered) || localizedName.contains(lowered)
      else { return nil }
      return InstrumentSearchResult(
        instrument: Instrument.fiat(code: code),
        cryptoMapping: nil,
        isRegistered: true,
        requiresResolution: false)
    }
  }

  // MARK: - Crypto

  private func cryptoMatches(query: String) async -> [InstrumentSearchResult] {
    if isContractAddress(query) {
      return await cryptoContractLookup(address: query)
    }
    do {
      let hits = try await cryptoSearchClient.search(query: query)
      return hits.map { hit in
        let placeholder = Instrument.crypto(
          chainId: 0, contractAddress: nil,
          symbol: hit.symbol, name: hit.name, decimals: 18)
        let mapping = CryptoProviderMapping(
          instrumentId: placeholder.id,
          coingeckoId: hit.coingeckoId,
          cryptocompareSymbol: nil, binanceSymbol: nil)
        return InstrumentSearchResult(
          instrument: placeholder,
          cryptoMapping: mapping,
          isRegistered: false,
          requiresResolution: true)
      }
    } catch {
      logger.warning(
        "Crypto search failed for query=\(query, privacy: .public): \(error, privacy: .public)"
      )
      return []
    }
  }

  private func cryptoContractLookup(address: String) async -> [InstrumentSearchResult] {
    do {
      // chainId 1 (Ethereum mainnet) is the most common; the follow-up UI
      // can expose a chain selector later.
      let result = try await resolutionClient.resolve(
        chainId: 1, contractAddress: address, symbol: nil, isNative: false)
      guard let coingeckoId = result.coingeckoId,
        let symbol = result.resolvedSymbol,
        let name = result.resolvedName,
        let decimals = result.resolvedDecimals
      else { return [] }
      let instrument = Instrument.crypto(
        chainId: 1, contractAddress: address,
        symbol: symbol, name: name, decimals: decimals)
      let mapping = CryptoProviderMapping(
        instrumentId: instrument.id,
        coingeckoId: coingeckoId,
        cryptocompareSymbol: result.cryptocompareSymbol,
        binanceSymbol: result.binanceSymbol)
      return [
        InstrumentSearchResult(
          instrument: instrument,
          cryptoMapping: mapping,
          isRegistered: false,
          requiresResolution: false)
      ]
    } catch {
      logger.warning(
        "Contract resolve failed for address=\(address, privacy: .public): \(error, privacy: .public)"
      )
      return []
    }
  }

  private func isContractAddress(_ query: String) -> Bool {
    let range = NSRange(query.startIndex..., in: query)
    return Self.contractAddressPattern.firstMatch(in: query, range: range) != nil
  }

  // MARK: - Stock

  private func stockMatches(query: String) async -> [InstrumentSearchResult] {
    do {
      guard let validated = try await stockValidator.validate(query: query) else {
        return []
      }
      let stock = Instrument.stock(
        ticker: validated.ticker, exchange: validated.exchange,
        name: validated.ticker, decimals: 0)
      return [
        InstrumentSearchResult(
          instrument: stock, cryptoMapping: nil,
          isRegistered: false, requiresResolution: false)
      ]
    } catch {
      logger.warning(
        "Stock validator failed for query=\(query, privacy: .public): \(error, privacy: .public)"
      )
      return []
    }
  }

  // MARK: - Merge + rank

  private func registeredMatches(
    query: String, all: [Instrument]
  ) -> [InstrumentSearchResult] {
    let lowered = query.lowercased()
    return all.compactMap { instrument in
      let id = instrument.id.lowercased()
      let ticker = instrument.ticker?.lowercased() ?? ""
      let name = instrument.name.lowercased()
      guard id.contains(lowered) || ticker.contains(lowered) || name.contains(lowered)
      else { return nil }
      return InstrumentSearchResult(
        instrument: instrument, cryptoMapping: nil,
        isRegistered: true, requiresResolution: false)
    }
  }

  private func merge(
    registered: [InstrumentSearchResult], provider: [InstrumentSearchResult]
  ) -> [InstrumentSearchResult] {
    var seen = Set<String>()
    var out: [InstrumentSearchResult] = []
    for result in registered where seen.insert(result.id).inserted {
      out.append(result)
    }
    for result in provider where seen.insert(result.id).inserted {
      out.append(result)
    }
    return out
  }
}
```

- [ ] **Step 5: Run tests**

```bash
just format
just generate
just test InstrumentSearchServiceTests 2>&1 | tee .agent-tmp/task8-mid.txt
```

Expected: all pass.

- [ ] **Step 6: Run reviews**

Run `@code-review` and `@concurrency-review` on this diff.

- [ ] **Step 7: Commit**

```bash
rm .agent-tmp/task8-*.txt
git add Shared/InstrumentSearchResult.swift \
        Shared/InstrumentSearchService.swift \
        MoolahTests/Shared/InstrumentSearchServiceTests.swift
git commit -m "$(cat <<'EOF'
feat(shared): add InstrumentSearchService + InstrumentSearchResult

Unified fan-out search over fiat (Locale.Currency.isoCurrencies),
crypto (CoinGecko /search + contract-address resolver path), and
stock (typed-ticker validated by StockTickerValidator). Stateless
struct — concurrent searches fan out in parallel rather than
serializing on an actor executor. Individual-kind failures are
absorbed and logged; the caller still receives the other kinds'
results.

No SwiftUI caller in this project; the service is wired into the
picker in the follow-up UI issue.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Update `ensureInstrument` to skip fiat

**Files:**
- Modify: `Backends/CloudKit/Repositories/CloudKitTransactionRepository.swift:49-58` — add guard.
- Modify: `Backends/CloudKit/Repositories/CloudKitAccountRepository.swift:~185-195` — same guard (it has a similar `ensureInstrument` path — verify by inspecting).
- Create or modify: `MoolahTests/Domain/EnsureInstrumentSkipFiatTests.swift`.

- [ ] **Step 1: Write the failing test**

`MoolahTests/Domain/EnsureInstrumentSkipFiatTests.swift`:

```swift
import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("ensureInstrument — skips fiat")
@MainActor
struct EnsureInstrumentSkipFiatTests {
  @Test
  func fiatDoesNotInsertInstrumentRecord() async throws {
    let backend = TestBackend.inMemory()
    let repo = backend.transactions as! CloudKitTransactionRepository
    let context = repo.modelContainer.mainContext

    try repo.ensureInstrument(Instrument.fiat(code: "EUR"))
    try context.save()

    let descriptor = FetchDescriptor<InstrumentRecord>(
      predicate: #Predicate { $0.id == "EUR" }
    )
    let rows = try context.fetch(descriptor)
    #expect(rows.isEmpty)
  }

  @Test
  func stockStillInserts() async throws {
    let backend = TestBackend.inMemory()
    let repo = backend.transactions as! CloudKitTransactionRepository
    let context = repo.modelContainer.mainContext

    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    try repo.ensureInstrument(bhp)
    try context.save()

    let descriptor = FetchDescriptor<InstrumentRecord>(
      predicate: #Predicate { $0.id == "ASX:BHP.AX" }
    )
    let rows = try context.fetch(descriptor)
    #expect(rows.count == 1)
  }
}
```

- [ ] **Step 2: Run tests to verify failure**

```bash
just test EnsureInstrumentSkipFiatTests 2>&1 | tee .agent-tmp/task9-pre.txt
```

Expected: `fiatDoesNotInsertInstrumentRecord` fails.

- [ ] **Step 3: Add guard in `ensureInstrument`**

In `Backends/CloudKit/Repositories/CloudKitTransactionRepository.swift`, the `ensureInstrument(_:)` method:

```swift
@MainActor
func ensureInstrument(_ instrument: Instrument) throws {
  guard instrument.kind != .fiatCurrency else {
    instrumentCache[instrument.id] = instrument
    return
  }
  let iid = instrument.id
  let descriptor = FetchDescriptor<InstrumentRecord>(predicate: #Predicate { $0.id == iid })
  if try context.fetch(descriptor).isEmpty {
    context.insert(InstrumentRecord.from(instrument))
    onInstrumentChanged(instrument.id)
  }
  instrumentCache[instrument.id] = instrument
}
```

Apply the same guard to any sibling `ensureInstrument` in `CloudKitAccountRepository.swift` (inspect the file at line ~185 — the existing grep in Task 1 showed `onInstrumentChanged(instrument.id)` at line 190).

- [ ] **Step 4: Run tests**

```bash
just format
just test EnsureInstrumentSkipFiatTests 2>&1 | tee .agent-tmp/task9-mid.txt
just test 2>&1 | tee .agent-tmp/task9-full.txt
grep -iE 'failed|error:' .agent-tmp/task9-full.txt | head -20
```

Expected: clean. The existing test suite should still pass — fiat `InstrumentRecord` was redundant, and `resolveInstrument` already falls back to `Instrument.fiat(code:)` when no row exists.

- [ ] **Step 5: Commit**

```bash
rm .agent-tmp/task9-*.txt
git add Backends/CloudKit/Repositories/CloudKitTransactionRepository.swift \
        Backends/CloudKit/Repositories/CloudKitAccountRepository.swift \
        MoolahTests/Domain/EnsureInstrumentSkipFiatTests.swift
git commit -m "$(cat <<'EOF'
refactor(cloudkit): skip fiat in ensureInstrument

Fiat instruments are served ambient by InstrumentRegistryRepository.all()
from Locale.Currency.isoCurrencies; writing a per-profile
InstrumentRecord row for a fiat code creates an unneeded duplicate
of a universal constant.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Change `FullConversionService.providerMappings` closure to throwing

**Files:**
- Modify: `Shared/FullConversionService.swift` — closure type + `cryptoUsdPrice` `try await` update.
- Modify: call sites — currently the only production call site is in `App/ProfileSession+Factories.swift` (CloudKit branch of `makeBackend`).
- Modify: test call sites — any test that constructs `FullConversionService` must pass a throwing closure.

- [ ] **Step 1: Find every `FullConversionService` construction**

```bash
grep -rn "FullConversionService(" . --include="*.swift" 2>&1 | grep -v '\.build\|\.worktrees/drop-' | tee .agent-tmp/task10-callers.txt
```

Expected: the production site in `ProfileSession+Factories.swift`, plus any test suites constructing it directly.

- [ ] **Step 2: Write a failing test that asserts the throw propagates**

`MoolahTests/Shared/FullConversionServiceErrorPropagationTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("FullConversionService — providerMappings throws")
struct FullConversionServiceErrorPropagationTests {
  struct FakeRegistryError: Error {}

  @Test
  func cryptoConversionPropagatesRegistryError() async throws {
    let service = FullConversionService(
      exchangeRates: StubExchangeRateService(),
      stockPrices: StubStockPriceService(),
      cryptoPrices: CryptoPriceService(
        clients: [],
        resolutionClient: NoOpTokenResolutionClient()
      ),
      providerMappings: { () async throws -> [CryptoProviderMapping] in
        throw FakeRegistryError()
      }
    )
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH",
      name: "Ethereum", decimals: 18)
    await #expect(throws: FakeRegistryError.self) {
      _ = try await service.convert(
        Decimal(1), from: eth, to: Instrument.USD, on: Date())
    }
  }
}
```

(Copy whatever `StubExchangeRateService`, `StubStockPriceService`, `NoOpTokenResolutionClient` patterns are already in use. If the real `ExchangeRateService` / `StockPriceService` are final types without easy substitution, inject known values via fixtures.)

- [ ] **Step 3: Run test to verify failure**

```bash
just generate
just test FullConversionServiceErrorPropagationTests 2>&1 | tee .agent-tmp/task10-pre.txt
```

Expected: fails — today the closure is non-throwing, so the `throw FakeRegistryError()` line won't even compile, or the error is swallowed.

- [ ] **Step 4: Update `FullConversionService`**

In `Shared/FullConversionService.swift`:

```swift
init(
  exchangeRates: ExchangeRateService,
  stockPrices: StockPriceService,
  cryptoPrices: CryptoPriceService,
  providerMappings: @Sendable @escaping () async throws -> [CryptoProviderMapping] = { [] }
)
```

In the internal `cryptoUsdPrice(for:on:)` (or wherever the closure is invoked), change `await providerMappings()` to `try await providerMappings()`. The `throws` propagates out through the containing method — which already propagates to `convert(_:from:to:on:)` via existing `try` chains.

- [ ] **Step 5: Update production call site**

In `App/ProfileSession+Factories.swift`, update the closure from `await cryptoPrices.registeredItems().map(\.mapping)` to the throwing form. Since the registry doesn't exist yet at this call site, keep the old body temporarily and wrap in a no-throw `do { ... } catch { ... }` that returns `[]` — wait, that defeats the purpose. Instead, do this in the same commit as the `try` update: change the closure to `{ try await cryptoPrices.registeredItems().map(\.mapping) }`. `registeredItems()` is non-throwing today, so `try` is redundant at the call site — Swift will accept but warn. Suppress with `_ =` or just let the no-op `try` be (it will disappear when we remove `registeredItems` in Task 15).

Alternatively, since this closure is rewritten in Task 14 anyway, a simpler path: land Task 10 and Task 14 together. That bundles the closure-type change with the actual new registry wiring. Mark this step as "see Task 14 for the production wiring" and at this step only update tests + the init signature.

**Decision for this plan:** split neatly — Task 10 updates the init signature + tests; Task 14 updates the production call site with the registry wiring. Between Task 10 merging and Task 14 merging, the production closure still pulls from `cryptoPrices.registeredItems()` (which is still alive) — wrap it `{ await cryptoPrices.registeredItems().map(\.mapping) }` directly; since it's non-throwing, the `throws` closure accepts a non-throwing body (sub-typing). No change needed at the production site until Task 14.

- [ ] **Step 6: Update any other test call sites**

Each test from Step 1 that constructs `FullConversionService` — if it passed a non-throwing closure, Swift should still accept it (subtype). But any closure that relied on non-throwing-ness to avoid `try` syntax errors stays valid. Nothing to change for passing closures.

- [ ] **Step 7: Run tests**

```bash
just format
just test 2>&1 | tee .agent-tmp/task10-full.txt
grep -iE 'failed|error:' .agent-tmp/task10-full.txt | head -20
```

Expected: clean, including the new `FullConversionServiceErrorPropagationTests`.

- [ ] **Step 8: Run reviews**

Run `@code-review` and `@instrument-conversion-review`.

- [ ] **Step 9: Commit**

```bash
rm .agent-tmp/task10-*.txt
git add Shared/FullConversionService.swift MoolahTests/Shared/FullConversionServiceErrorPropagationTests.swift
git commit -m "$(cat <<'EOF'
refactor(conversion): make providerMappings closure throwing

Error from the mapping source (registry read, network, etc.) now
propagates through FullConversionService.convert rather than being
silently collapsed to an empty mapping table that would surface as a
spurious noProviderMapping error. Aligns with the instrument-conversion
guide's Rule 11 (failed conversions must be surfaced, not silently
substituted).

Non-throwing closures remain accepted via Swift's throws-subtype
relationship, so existing call sites compile unchanged. The CryptoPriceService
wiring in ProfileSession+Factories will be replaced with a registry-based
throwing body in the integration task.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: Rewire `CryptoTokenStore` to use `InstrumentRegistryRepository`

**Files:**
- Modify: `Features/Settings/CryptoTokenStore.swift` — inject registry; update `loadRegistrations` / `confirmRegistration` / `removeRegistration` to route through it; surface errors via the existing `error` property.
- Modify: `MoolahTests/Features/CryptoTokenStoreTests.swift` — switch from `InMemoryTokenRepository` to `CloudKitInstrumentRegistryRepository` on an in-memory `ModelContainer`; add error-path tests.

- [ ] **Step 1: Update the tests first (TDD)**

Modify `MoolahTests/Features/CryptoTokenStoreTests.swift`:

```swift
// Replace the existing test fixture with:
@MainActor
func makeStore(registrations: [CryptoRegistration] = []) async -> (
  CryptoTokenStore, CloudKitInstrumentRegistryRepository
) {
  let config = ModelConfiguration(isStoredInMemoryOnly: true)
  let container = try! ModelContainer(
    for: InstrumentRecord.self, configurations: [config])
  let registry = CloudKitInstrumentRegistryRepository(modelContainer: container)
  for reg in registrations {
    try! await registry.registerCrypto(reg.instrument, mapping: reg.mapping)
  }
  let service = CryptoPriceService(
    clients: [],
    resolutionClient: NoOpTokenResolutionClient())
  let store = CryptoTokenStore(registry: registry, cryptoPriceService: service)
  return (store, registry)
}
```

Add a test for error-path surface:

```swift
@Test("loadRegistrations surfaces registry failure into error")
@MainActor
func loadRegistrationsSurfacesError() async {
  let failing = FailingRegistry()
  let service = CryptoPriceService(
    clients: [], resolutionClient: NoOpTokenResolutionClient())
  let store = CryptoTokenStore(registry: failing, cryptoPriceService: service)
  await store.loadRegistrations()
  #expect(store.error != nil)
  #expect(store.registrations.isEmpty)
}

// ... and at end of file:
private struct FailingRegistry: InstrumentRegistryRepository, @unchecked Sendable {
  struct BoomError: Error {}
  func all() async throws -> [Instrument] { throw BoomError() }
  func allCryptoRegistrations() async throws -> [CryptoRegistration] { throw BoomError() }
  func registerCrypto(
    _ instrument: Instrument, mapping: CryptoProviderMapping
  ) async throws { throw BoomError() }
  func registerStock(_ instrument: Instrument) async throws { throw BoomError() }
  func remove(instrumentId: String) async throws { throw BoomError() }
  func observeChanges() -> AsyncStream<Void> { AsyncStream { _ in } }
}
```

Also: the existing tests reference `tokenRepository:` argument — update every `makeStore(...)` call to the new signature.

- [ ] **Step 2: Run tests to verify they fail**

```bash
just test CryptoTokenStoreTests 2>&1 | tee .agent-tmp/task11-pre.txt
```

Expected: compile errors — `CryptoTokenStore.init(registry:cryptoPriceService:)` doesn't exist yet; `tokenRepository:` is still the init param.

- [ ] **Step 3: Rewire `CryptoTokenStore`**

In `Features/Settings/CryptoTokenStore.swift`:

```swift
// Features/Settings/CryptoTokenStore.swift
import Foundation
import OSLog

@MainActor
@Observable
final class CryptoTokenStore {
  private(set) var registrations: [CryptoRegistration] = []
  private(set) var instruments: [Instrument] = []
  private(set) var providerMappings: [String: CryptoProviderMapping] = [:]

  private(set) var isLoading = false
  private(set) var isResolving = false

  var resolvedRegistration: CryptoRegistration?

  private(set) var error: String?

  private let registry: any InstrumentRegistryRepository
  private let cryptoPriceService: CryptoPriceService
  private let logger = Logger(
    subsystem: "com.moolah.app", category: "CryptoTokenStore")

  private let apiKeyStore = KeychainStore(
    service: "com.moolah.api-keys", account: "coingecko", synchronizable: true
  )

  init(
    registry: any InstrumentRegistryRepository,
    cryptoPriceService: CryptoPriceService
  ) {
    self.registry = registry
    self.cryptoPriceService = cryptoPriceService
  }

  func loadRegistrations() async {
    isLoading = true
    defer { isLoading = false }
    do {
      let loaded = try await registry.allCryptoRegistrations()
      registrations = loaded
      instruments = loaded.map(\.instrument)
      providerMappings = Dictionary(
        loaded.map { ($0.mapping.instrumentId, $0.mapping) },
        uniquingKeysWith: { _, last in last }
      )
      error = nil
    } catch {
      logger.error(
        "Failed to load crypto registrations: \(error, privacy: .public)")
      self.error = error.localizedDescription
    }
  }

  func removeRegistration(_ registration: CryptoRegistration) async {
    do {
      try await registry.remove(instrumentId: registration.id)
      await cryptoPriceService.purgeCache(instrumentId: registration.id)
      registrations.removeAll { $0.id == registration.id }
      instruments.removeAll { $0.id == registration.id }
      providerMappings.removeValue(forKey: registration.id)
    } catch {
      logger.error(
        "Failed to remove registration: \(error, privacy: .public)")
      self.error = error.localizedDescription
    }
  }

  func removeInstrument(_ instrument: Instrument) async {
    guard let registration = registrations.first(where: {
      $0.instrument.id == instrument.id
    }) else { return }
    await removeRegistration(registration)
  }

  func resolveToken(
    chainId: Int, contractAddress: String?, symbol: String?, isNative: Bool
  ) async {
    isResolving = true
    resolvedRegistration = nil
    error = nil
    defer { isResolving = false }

    do {
      resolvedRegistration = try await cryptoPriceService.resolveRegistration(
        chainId: chainId,
        contractAddress: contractAddress,
        symbol: symbol,
        isNative: isNative
      )
    } catch {
      self.error = "Resolution failed: \(error.localizedDescription)"
    }
  }

  func confirmRegistration() async {
    guard let registration = resolvedRegistration else { return }
    do {
      try await registry.registerCrypto(
        registration.instrument, mapping: registration.mapping)
      registrations.append(registration)
      instruments.append(registration.instrument)
      providerMappings[registration.mapping.instrumentId] = registration.mapping
      resolvedRegistration = nil
    } catch {
      logger.error(
        "Failed to confirm registration: \(error, privacy: .public)")
      self.error = error.localizedDescription
    }
  }

  // MARK: - API Key

  var hasApiKey: Bool {
    (try? apiKeyStore.restoreString()) != nil
  }

  func saveApiKey(_ key: String) {
    do {
      try apiKeyStore.saveString(key)
    } catch {
      self.error = "Failed to save API key: \(error.localizedDescription)"
    }
  }

  func clearApiKey() {
    apiKeyStore.clear()
  }
}
```

- [ ] **Step 4: Run tests**

```bash
just format
just generate
just test CryptoTokenStoreTests 2>&1 | tee .agent-tmp/task11-mid.txt
```

Expected: all pass.

- [ ] **Step 5: Run reviews**

Run `@code-review` and `@concurrency-review`. Note: there may be callers of the old `init(cryptoPriceService:)` elsewhere in `ProfileSession` / previews — those are updated in Task 14. For now, the project may not compile outside the test target; that is expected and will be resolved by Task 14.

- [ ] **Step 6: Verify scoped tests still pass even while non-test modules have integration breakage**

Scope the test run to the store tests only; full-project compilation is deferred to Task 14.

- [ ] **Step 7: Commit**

```bash
rm .agent-tmp/task11-*.txt
git add Features/Settings/CryptoTokenStore.swift MoolahTests/Features/CryptoTokenStoreTests.swift
git commit -m "$(cat <<'EOF'
refactor(settings): route CryptoTokenStore through InstrumentRegistryRepository

Replaces direct CryptoPriceService.register/remove/registeredItems calls
with registry.registerCrypto / remove / allCryptoRegistrations. Errors
now surface into the store's error property and log via os.Logger,
replacing the silent try? swallow in the previous implementation.

NOTE: ProfileSession / SettingsView callers are updated in Task 14.
This commit temporarily breaks app-target compilation until the
wiring task lands. Scope tests to CryptoTokenStoreTests.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

If the project convention is that every commit must compile, bundle Tasks 11–14 into a single PR instead. In that case, skip committing here and continue to Task 14 on the same branch.

---

## Task 12: Strip `CryptoPriceService` registration surface

Remove `registeredItems`, `register(_:)`, `remove(_:)`, `removeById(_:)`, zero-arg `prefetchLatest()`, and the `tokenRepository` init parameter. Keep `resolveRegistration`, `price`, `prices`, `currentPrices`, `prefetchLatest(for:)`, and the new `purgeCache` from Task 5.

**Files:**
- Modify: `Shared/CryptoPriceService.swift`
- Modify: `MoolahTests/Shared/CryptoPriceServiceTests.swift`, `MoolahTests/Shared/CryptoPriceServiceTestsMore.swift` — delete tests exercising the removed methods; keep tests exercising the kept methods.

- [ ] **Step 1: Remove surface from `CryptoPriceService`**

```swift
// Shared/CryptoPriceService.swift (relevant portions)
actor CryptoPriceService {
  private let clients: [CryptoPriceClient]
  private var caches: [String: CryptoPriceCache] = [:]
  private let cacheDirectory: URL
  private let dateFormatter: ISO8601DateFormatter
  private let resolutionClient: TokenResolutionClient

  init(
    clients: [CryptoPriceClient],
    cacheDirectory: URL? = nil,
    resolutionClient: (any TokenResolutionClient)? = nil
  ) {
    self.clients = clients
    self.resolutionClient = resolutionClient ?? NoOpTokenResolutionClient()
    if let cacheDirectory {
      self.cacheDirectory = cacheDirectory
    } else {
      let baseCaches =
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSTemporaryDirectory())
      self.cacheDirectory = baseCaches.appendingPathComponent("crypto-prices")
    }
    self.dateFormatter = ISO8601DateFormatter()
    self.dateFormatter.formatOptions = [.withFullDate]
  }

  // DELETE: registeredItems(), register(_:), remove(_:), removeById(_:),
  //         the zero-arg prefetchLatest().

  // Keep prefetchLatest(for: [CryptoRegistration]) unchanged.
  // Keep purgeCache(instrumentId:) unchanged (added in Task 5).
  // Keep resolveRegistration, price, prices, currentPrices unchanged.
}
```

- [ ] **Step 2: Delete tests for removed methods**

In `CryptoPriceServiceTests.swift` / `CryptoPriceServiceTestsMore.swift`, delete every test that calls `registeredItems`, `register`, `remove`, `removeById`, or the zero-arg `prefetchLatest`. These are listed in §6.4 of the design doc. Keep tests for `price`, `prices`, `currentPrices`, `resolveRegistration`, disk cache, `prefetchLatest(for:)`, and `purgeCache`.

Also delete or update any `StubCryptoTokenRepository` / `InMemoryTokenRepository` usages inside these test files — they'll be fully removed in Task 15.

- [ ] **Step 3: Run scoped tests**

```bash
just format
just test CryptoPriceServiceTests 2>&1 | tee .agent-tmp/task12-mid.txt
just test CryptoPriceServiceTestsMore 2>&1 | tee .agent-tmp/task12-mid2.txt
```

Expected: all pass.

- [ ] **Step 4: Commit (bundled with Task 11 if single-PR approach chosen)**

```bash
rm .agent-tmp/task12-*.txt
git add Shared/CryptoPriceService.swift \
        MoolahTests/Shared/CryptoPriceServiceTests.swift \
        MoolahTests/Shared/CryptoPriceServiceTestsMore.swift
git commit -m "$(cat <<'EOF'
refactor(shared): strip registration surface from CryptoPriceService

Remove registeredItems / register / remove / removeById / zero-arg
prefetchLatest / tokenRepository init parameter. The registry is now
the authoritative source for crypto registrations; this actor is a
focused price-fetch + cache + resolver.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 13: Thread `instrumentRegistry` through `CloudKitBackend` and `ProfileSession`

**Files:**
- Modify: `Backends/CloudKit/CloudKitBackend.swift` — add `instrumentRegistry` stored property + init parameter.
- Modify: `App/ProfileSession.swift` — add optional `instrumentRegistry` + make `cryptoTokenStore` optional.
- Modify: `App/UITestSeedHydrator+Upserts.swift` or any fixture that constructs `CryptoTokenStore` — construct only when a registry is available.

- [ ] **Step 1: Extend `CloudKitBackend`**

In `Backends/CloudKit/CloudKitBackend.swift`:

```swift
final class CloudKitBackend: BackendProvider, @unchecked Sendable {
  // ...existing properties...
  let instrumentRegistry: any InstrumentRegistryRepository

  init(
    modelContainer: ModelContainer,
    instrument: Instrument,
    profileLabel: String,
    conversionService: any InstrumentConversionService,
    instrumentRegistry: any InstrumentRegistryRepository
  ) {
    // ...existing assignments...
    self.instrumentRegistry = instrumentRegistry
    // ...rest of init...
  }
}
```

- [ ] **Step 2: Extend `ProfileSession`**

In `App/ProfileSession.swift`, add an optional stored property:

```swift
let instrumentRegistry: (any InstrumentRegistryRepository)?
let cryptoTokenStore: CryptoTokenStore?   // was non-optional
```

Update `ProfileSession.init` to assign `instrumentRegistry` from the backend when it's a `CloudKitBackend`, and nil otherwise. `cryptoTokenStore` is constructed with the registry when one exists; nil otherwise.

- [ ] **Step 3: Update fixtures / hydrators**

Any place that constructs a `CryptoTokenStore` (grep `CryptoTokenStore(`) must:
- Provide a registry (test fixtures already do in Task 11).
- Or guard on the session's registry being non-nil (UI seed hydrator, previews).

- [ ] **Step 4: Tests**

Write or extend a test asserting:
- A CloudKit-backed profile session has a non-nil `instrumentRegistry`.
- A Remote-backed profile session has a nil `instrumentRegistry` and nil `cryptoTokenStore`.

`MoolahTests/App/ProfileSessionInstrumentRegistryTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("ProfileSession — instrumentRegistry wiring")
@MainActor
struct ProfileSessionInstrumentRegistryTests {
  @Test
  func cloudKitProfileHasRegistry() throws {
    let session = try ProfileSession.makeForTest(
      backendType: .cloudKit)
    #expect(session.instrumentRegistry != nil)
    #expect(session.cryptoTokenStore != nil)
  }

  @Test
  func remoteProfileHasNoRegistry() throws {
    let session = try ProfileSession.makeForTest(
      backendType: .remote)
    #expect(session.instrumentRegistry == nil)
    #expect(session.cryptoTokenStore == nil)
  }
}
```

(If `ProfileSession.makeForTest` doesn't exist, build a minimal fixture that reaches the constructor.)

- [ ] **Step 5: Run full suite**

```bash
just format
just generate
just test 2>&1 | tee .agent-tmp/task13-full.txt
grep -iE 'failed|error:' .agent-tmp/task13-full.txt | head -30
```

Expected: clean.

- [ ] **Step 6: Commit**

```bash
rm .agent-tmp/task13-*.txt
git add Backends/CloudKit/CloudKitBackend.swift \
        App/ProfileSession.swift \
        App/UITestSeedHydrator+Upserts.swift \
        MoolahTests/App/ProfileSessionInstrumentRegistryTests.swift
git commit -m "$(cat <<'EOF'
feat(app): thread instrumentRegistry through CloudKitBackend + ProfileSession

CloudKitBackend gains an instrumentRegistry property; ProfileSession
exposes it as an optional. CryptoTokenStore likewise becomes optional
because it only makes sense for CloudKit-backed profiles (Remote is
single-instrument and has no registry concept). All non-test callers
that accessed session.cryptoTokenStore unconditionally are updated to
guard on the optional.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 14: `ProfileSession+Factories` wiring + settings view gating

**Files:**
- Modify: `App/ProfileSession+Factories.swift` — CloudKit branch of `makeBackend` constructs the registry and passes it to `CloudKitBackend`; closure rewritten.
- Modify: the `ProfileSession.makeCryptoPriceService()` helper — remove `tokenRepository:` argument.
- Modify: `App/ProfileSession.swift` — on-load prefetch uses registry + new logging pattern.
- Modify: `Features/Settings/SettingsView.swift` — macOS gating on active profile's registry.
- Modify: `Features/Settings/SettingsView+iOS.swift` — iOS gating; delete `cryptoTokenStoreForSettings` fallback.

- [ ] **Step 1: Update `makeCryptoPriceService`**

In `App/ProfileSession+Factories.swift`, the `makeCryptoPriceService()` static method drops the `tokenRepository:` argument to match Task 12's init signature:

```swift
static func makeCryptoPriceService() -> CryptoPriceService {
  // ... existing body up through priceClients build ...
  let apiKeyStore = KeychainStore(
    service: "com.moolah.api-keys", account: "coingecko", synchronizable: true)
  let coinGeckoApiKey = try? apiKeyStore.restoreString()

  var priceClients: [CryptoPriceClient] = []
  if let coinGeckoApiKey, !coinGeckoApiKey.isEmpty {
    priceClients.append(CoinGeckoClient(apiKey: coinGeckoApiKey))
  }
  priceClients.append(cryptoCompareClient)
  priceClients.append(binanceClient)

  return CryptoPriceService(
    clients: priceClients,
    resolutionClient: CompositeTokenResolutionClient(coinGeckoApiKey: coinGeckoApiKey)
  )
}
```

- [ ] **Step 2: Update CloudKit branch of `makeBackend`**

```swift
case .cloudKit:
  guard let containerManager else {
    fatalError("ProfileContainerManager is required for CloudKit profiles")
  }
  // swiftlint:disable:next force_try
  let profileContainer = try! containerManager.container(for: profile.id)
  let registry = CloudKitInstrumentRegistryRepository(
    modelContainer: profileContainer,
    onRecordChanged: { [weak containerManager, profileId = profile.id] id in
      containerManager?.syncCoordinator(for: profileId)?
        .queueSave(recordName: id, zoneID: profileZoneID(for: profileId))
    },
    onRecordDeleted: { [weak containerManager, profileId = profile.id] id in
      containerManager?.syncCoordinator(for: profileId)?
        .queueDeletion(recordName: id, zoneID: profileZoneID(for: profileId))
    }
  )
  let conversionService = FullConversionService(
    exchangeRates: exchangeRates,
    stockPrices: stockPrices,
    cryptoPrices: cryptoPrices,
    providerMappings: {
      try await registry.allCryptoRegistrations().map(\.mapping)
    }
  )
  return CloudKitBackend(
    modelContainer: profileContainer,
    instrument: profile.instrument,
    profileLabel: profile.label,
    conversionService: conversionService,
    instrumentRegistry: registry
  )
```

`profileZoneID(for:)` and `containerManager.syncCoordinator(for:)` must exist or be added based on the existing `SyncCoordinator` API. Inspect `ProfileContainerManager.swift` and `SyncCoordinator+Lifecycle.swift` to find the right accessors.

- [ ] **Step 3: Update on-load prefetch**

Wherever `ProfileSession` currently calls the zero-arg `cryptoPriceService.prefetchLatest()` (search for `prefetchLatest()`), replace with:

```swift
if let registry = self.instrumentRegistry {
  do {
    let regs = try await registry.allCryptoRegistrations()
    if !regs.isEmpty {
      await cryptoPriceService.prefetchLatest(for: regs)
    }
  } catch {
    logger.warning(
      "Skipping crypto prefetch — registry read failed: \(error, privacy: .public)"
    )
  }
}
```

- [ ] **Step 4: Gate iOS Crypto Settings**

In `Features/Settings/SettingsView+iOS.swift`, delete `cryptoTokenStoreForSettings`. Update `cryptoSection` to use the session's `cryptoTokenStore` and hide the link when it's nil:

```swift
var cryptoSection: some View {
  Group {
    if let store = activeSession?.cryptoTokenStore {
      Section {
        NavigationLink {
          CryptoSettingsView(store: store)
        } label: {
          Label("Crypto Tokens", systemImage: "bitcoinsign.circle")
        }
      }
    }
  }
}
```

- [ ] **Step 5: Gate macOS Crypto Settings**

In `Features/Settings/SettingsView.swift`, replace any `sessionManager.sessions.values.first` lookup for the crypto store with an `activeProfileID`-keyed lookup. If the existing code path constructs `CryptoTokenStore` on the fly via `ICloudTokenRepository()`, delete that path and pull from `activeSession.cryptoTokenStore`:

```swift
// inside the settings content:
if let activeId = profileStore.activeProfileID,
   let session = sessionManager.sessions[activeId],
   let store = session.cryptoTokenStore {
  // show crypto settings
} else {
  // hide crypto settings
}
```

- [ ] **Step 6: Run tests and manually verify**

```bash
just format
just generate
just test 2>&1 | tee .agent-tmp/task14-full.txt
just run-mac    # manual smoke: settings → crypto only shows for active CloudKit profile
```

- [ ] **Step 7: Run reviews**

`@code-review`, `@concurrency-review`, `@sync-review`, `@instrument-conversion-review`. This is the largest wiring change.

- [ ] **Step 8: Commit**

```bash
rm .agent-tmp/task14-*.txt
git add App/ProfileSession+Factories.swift \
        App/ProfileSession.swift \
        Features/Settings/SettingsView.swift \
        Features/Settings/SettingsView+iOS.swift
git commit -m "$(cat <<'EOF'
feat(app): wire InstrumentRegistryRepository through ProfileSession

CloudKit profiles construct CloudKitInstrumentRegistryRepository in
makeBackend and pass it to CloudKitBackend. The conversion service's
providerMappings closure now reads throughs the registry directly;
errors propagate rather than being silently collapsed.

Settings views gate on the active session's cryptoTokenStore being
non-nil, covering both "no active profile" and "active profile is
Remote" cases in a single check. Removes the broken fallback path
that constructed a CryptoPriceService with the now-deleted
ICloudTokenRepository.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 15: Delete `ICloudTokenRepository`, `CryptoTokenRepository`, and test doubles

The final deletion PR — removes the sole user of `NSUbiquitousKeyValueStore`.

**Files:**
- Delete: `Backends/ICloud/ICloudTokenRepository.swift`
- Delete: `Backends/ICloud/` directory (empty after the above)
- Delete: `Domain/Repositories/CryptoTokenRepository.swift`
- Delete: `MoolahTests/Support/InMemoryTokenRepository.swift`
- Delete: `MoolahTests/Domain/CryptoTokenRepositoryTests.swift` (if it exists — use `ls MoolahTests/Domain/ | grep CryptoToken` to check)

- [ ] **Step 1: Verify zero remaining callers**

```bash
grep -rn "ICloudTokenRepository\|CryptoTokenRepository\|InMemoryTokenRepository\|NSUbiquitousKeyValueStore" \
  --include="*.swift" . 2>&1 | grep -v '\.build\|\.worktrees' | tee .agent-tmp/task15-callers.txt
```

Expected output: every hit is inside one of the files to be deleted in this task; no hits in `App/`, `Features/`, `Shared/`, or any other `Backends/` subdir. If any external reference remains, track it back to the earlier task that should have removed it and do that fix first.

- [ ] **Step 2: Delete files**

```bash
git rm Backends/ICloud/ICloudTokenRepository.swift
rmdir Backends/ICloud
git rm Domain/Repositories/CryptoTokenRepository.swift
git rm MoolahTests/Support/InMemoryTokenRepository.swift
[ -f MoolahTests/Domain/CryptoTokenRepositoryTests.swift ] \
  && git rm MoolahTests/Domain/CryptoTokenRepositoryTests.swift
```

- [ ] **Step 3: Regenerate, build, and run full test suite**

```bash
just format
just generate
just build-mac 2>&1 | tee .agent-tmp/task15-build.txt
just test 2>&1 | tee .agent-tmp/task15-full.txt
grep -iE 'failed|error:' .agent-tmp/task15-full.txt | head -20
```

Expected: clean.

- [ ] **Step 4: Run reviews**

`@code-review` and `@appstore-review` — the latter to confirm no entitlement change is needed (should confirm zero hits for `com.apple.developer.ubiquity-kvstore-identifier`).

- [ ] **Step 5: Commit**

```bash
rm .agent-tmp/task15-*.txt
git commit -m "$(cat <<'EOF'
refactor: delete ICloudTokenRepository and CryptoTokenRepository

Removes the sole user of NSUbiquitousKeyValueStore. Crypto-token
registration now flows entirely through InstrumentRegistryRepository
(CloudKit-synced per profile). Closes the long-standing BUG IN CLIENT
OF KVS log by eliminating the API rather than by adding the missing
entitlement.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 16: Follow-up GitHub issue, final sanity sweep, post-merge verification

**Files:** none (process task).

- [ ] **Step 1: File the follow-up GitHub issue**

```bash
gh issue create \
  --title "Instrument registry UI: unified picker & call-site migration" \
  --body "$(cat <<'EOF'
Follow-up to the instrument-registry backend work (plans/2026-04-24-instrument-registry-design.md). The registry, repository, and search service now exist; the UI has not yet been updated to take advantage of them.

**In scope for this issue**

- Build a generic `InstrumentPicker` SwiftUI view that uses `InstrumentSearchService`.
  - Shows the profile's registered instruments first, then on-type search results grouped by kind (Currency / Stock / Crypto).
  - Selecting an unregistered crypto search result runs `TokenResolutionClient` then writes to the registry via `registerCrypto(_:mapping:)`.
  - Selecting an unregistered stock result validates via `StockTickerValidator` then writes via `registerStock(_:)`.
  - Fiat selection is always immediate (ambient).
- Replace `CurrencyPicker` call sites with `InstrumentPicker` filtered to `.fiatCurrency`:
  - Profile creation (`ProfileFormView`).
  - Account creation / editing.
  - Transaction forms where currency overrides the account.
- Redesign the Crypto Settings "Add Token" flow to sit on top of `InstrumentSearchService` rather than the current contract-address form.
- "Resolve mapping" affordance for crypto `InstrumentRecord` rows that exist but have no provider mapping (e.g. inserted by CSV import via `ensureInstrument`). When a position references such a row and the conversion service returns `ConversionError.noProviderMapping`, the picker exposes a "Resolve" action that runs `TokenResolutionClient` and upserts the mapping via `registerCrypto`.
- Unified local + remote change signal so the picker updates when another device registers an instrument. Today `InstrumentRegistryRepository.observeChanges()` fires only for local writes; remote changes arrive through `CKSyncEngine` → `batchUpsertInstruments` and bypass the registry's fan-out. Bridge the two signals so the UI has a single subscription.
- Find or integrate a stock-name source so stock search can match on company name, not just ticker.

**Separate technical-debt issue to file alongside this one**

- Remove `InstrumentRecord`'s hand-written init and `from(_:)` factory in favour of the synthesized memberwise init. Deferred because `@Model`-macro synthesized-init interactions warrant isolated verification.

**Out of scope**

- Server-side changes.
- Remote / moolah-server profile support (single-instrument backends; registry doesn't apply).
EOF
)"
```

Record the issue number for the commit message and the design doc's §7.3 reference.

- [ ] **Step 2: Post-merge sanity sweep**

```bash
grep -rn "NSUbiquitousKeyValueStore\|ICloudTokenRepository\|CryptoTokenRepository" \
  --include="*.swift" . 2>&1 | grep -v '\.build\|\.worktrees'
grep -rn "com.apple.developer.ubiquity-kvstore-identifier" . 2>&1 \
  | grep -v '\.build\|\.worktrees\|\.git'
```

Expected: zero matches for all four searches.

- [ ] **Step 3: Manual smoke test — bug is actually fixed**

```bash
just run-mac-with-logs 'subsystem == "com.moolah.app"' &
```

Steps in the running app:
1. Open Settings → Crypto Tokens (should appear only if a CloudKit profile is active).
2. Register a token via the existing Add Token form (e.g., Bitcoin or any existing preset).
3. Quit and relaunch the app.
4. Re-open Crypto Settings → the token is still there.
5. Inspect captured logs:

```bash
grep "BUG IN CLIENT OF KVS" .agent-tmp/app-logs.txt
```

Expected: no matches.

- [ ] **Step 4: CloudKit Production schema deployment**

Per SYNC_GUIDE and spec §7.2:
1. Upload a TestFlight build in the Development environment.
2. On a TestFlight device, register one crypto token (fills `coingeckoId` / `cryptocompareSymbol` / `binanceSymbol`).
3. In CloudKit Dashboard → `CD_InstrumentRecord` → Development schema, confirm the three new fields appear.
4. Deploy Development schema to Production via the Dashboard.

Only after step 4 is a production build safe to distribute.

- [ ] **Step 5: Move completed plan**

Per project convention, move the design and implementation files to `plans/completed/`:

```bash
git mv plans/2026-04-24-instrument-registry-design.md plans/completed/
git mv plans/2026-04-24-instrument-registry-implementation.md plans/completed/
git commit -m "chore(plans): mark instrument-registry plan complete"
```

---

## Self-Review Checklist

- ✅ Spec coverage — every design section maps to a task:
  - Scope & non-goals (spec §Scope) → set by this plan's scope statement.
  - Data model (spec §1) → Tasks 2, 3, 4.
  - Search service (spec §2) → Tasks 6, 7, 8.
  - Service wiring (spec §3) → Tasks 10, 11, 12, 13, 14.
  - Deletions (spec §4) → Task 15.
  - Migration (spec §5) → Task 2 (schema), Task 14 (crypto settings gate), Task 16 (post-merge).
  - Testing (spec §6) → each task lists its tests inline.
  - Rollout (spec §7) → Task 16, including CloudKit Dashboard deploy.
  - `Instrument.stock` id formula (spec §1.2 + §6.1a) → Task 1.
- ✅ No `TBD` / `TODO` placeholders in the plan (Task 16's schema-deploy step is imperative, not a placeholder).
- ✅ Type and method names are consistent across tasks (`registerCrypto` / `registerStock` / `remove(instrumentId:)` / `observeChanges()` / `allCryptoRegistrations()` / `purgeCache(instrumentId:)`).
- ✅ Test-first discipline throughout — every task that adds behaviour writes the failing test first.
- ✅ Frequent commits — each task is one coherent commit.
