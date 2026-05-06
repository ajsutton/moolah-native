# Crypto Wallet Auto-Import — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the auto-import pipeline specified in `plans/2026-05-05-crypto-wallet-import-design.md` — wallets on Ethereum, OP Mainnet, Base, and Polygon are added to Moolah and stay current automatically.

**Architecture:** Per-account parallel build phase produces `[BuiltTransaction]` without writes; a single sequential `@MainActor` apply pass does cross-account merging, dedup, persist, rules, and state update. Token discovery is actor-coalesced. Pricing status is a discriminated `.priced` / `.unpriced` / `.spam` and the conversion service surfaces a discriminated `.priced(rate) / .knownZero / throws` so "unpriced" stays distinct from "rate unavailable" everywhere.

**Tech Stack:** Swift 6, SwiftUI, GRDB (local store), CloudKit (sync transport), Alchemy (data provider), Swift Testing.

**Source spec:** `plans/2026-05-05-crypto-wallet-import-design.md` — read it first.
**Related (still-Draft) spec:** `plans/2026-04-18-transfer-detection-design.md` — extended in Stage 7 of this plan.

**Reference reads before starting any stage:**
- `CLAUDE.md` (build/test, architecture, formatting, agent invocation).
- `guides/CONCURRENCY_GUIDE.md`, `guides/SYNC_GUIDE.md`, `guides/INSTRUMENT_CONVERSION_GUIDE.md`, `guides/CODE_GUIDE.md`, `guides/DATABASE_SCHEMA_GUIDE.md`, `guides/DATABASE_CODE_GUIDE.md`, `guides/TEST_GUIDE.md`.
- `Backends/CoinGecko/CoinGeckoClient.swift` — the canonical URLSession-client shape `AlchemyClient` should mirror.
- `Domain/Repositories/BackendProvider.swift` — DI root.
- `Domain/Models/CryptoRegistration.swift`, `Backends/GRDB/Repositories/GRDBInstrumentRegistryRepository.swift` — the existing GRDB-backed registry.

---

## Workflow conventions across all stages

- **One worktree per stage.** Create with `git -C <repo> worktree add --no-track .worktrees/<stage-name> -b <branch> origin/main`. Never push to a parent branch (see CLAUDE.md "Stacked-PR worktrees").
- **Format and warning-clean before every commit.** `just format` then verify `just format-check` is clean. Per CLAUDE.md "Pre-Commit Checklist".
- **Tests via `just`.** `just test <Filter>` then `just test` for the full sweep. Capture output to `.agent-tmp/<stage>-test.txt`.
- **Schema changes via `just generate`.** Edits to `CloudKit/schema.ckdb` are followed by `just generate` to regenerate `Backends/CloudKit/Sync/Generated/`.
- **Reviewer agents per stage.** After implementation, run the agents listed in each stage's "Pre-PR review" section. Apply every Critical / Important / Minor finding. Do not defer (per memory `feedback_apply_all_review_findings`).
- **PR via merge queue.** Open PR with `gh pr create`, then add to merge queue via the `merge-queue` skill (per memory `feedback_prs_to_merge_queue`). Each stage's "Land" step does this.
- **No bare `// TODO`.** Every TODO that survives must be `TODO(#N): reason — https://github.com/ajsutton/moolah-native/issues/N`. The "Open issues to file before coding" item at the head of each stage lists what to file.
- **No SwiftLint baseline edits.** If a violation surfaces, fix the underlying code (split file/type, rename, etc.) per memory `feedback_swiftlint_fix_not_baseline`.

---

## Stage map

| # | Stage | One-line scope | Depends on |
|---|---|---|---|
| 1 | Foundation: domain types + schema | New types, `Account` extensions, `TransactionLeg.externalId`, `WalletSyncState`, CloudKit + GRDB migrations. No behavioural changes. | — |
| 2 | Discriminated conversion semantics | `CryptoPriceLookup`, `ConversionResult`, `invalidateCache`, aggregation-site audit + fixes. | 1 |
| 3 | `pricingStatus` lifecycle | Column migration, sync apply-batch merge rule, cache-invalidation hook on user mutation. | 1, 2 |
| 4 | Wallet data layer | `ChainConfig`, `AlchemyClient`, `RateLimiter`, `WalletSyncStateRepository` (GRDB + in-memory). | 1 |
| 5 | Token discovery actor | `CryptoTokenDiscoveryService` (in-flight coalescer) + cross-device merge tests. | 2, 3, 4 |
| 6 | Build pipeline | `TransferEventBuilder`, `WalletSyncEngine` build phase (no writes). | 4, 5 |
| 7 | Apply pipeline + transfer-detection extension | `CrossAccountTransferMerger`, sequential `@MainActor` apply pass, eligibility-predicate + same-`externalId` extension to the transfer-detection design. | 6 |
| 8 | Cross-device deduper | `CrossDeviceLegDeduper` post-CKSyncEngine pass. | 7 |
| 9 | Orchestration store | `CryptoSyncStore`: triggers, scenePhase, hourly timer with cancellation, clock injection. | 7 |
| 10 | UI: account creation | `CryptoAccountCreationView`, type picker integration. | 9 |
| 11 | UI: settings | `CryptoSettingsView` updates (key, accounts list, Discovered Tokens, spam list). | 5, 9 |
| 12 | UI: wallet view + transaction detail | Wallet header, explorer links, leg-level explorer link. | 10 |
| 13 | Benchmarks | Signposts + benchmark tests. | 12 |

Stages 1–4 can be implemented in two parallel worktrees if helpful (1, 4 are independent; 2 and 3 chain off 1). Stages 5+ sequence.

---

## Open issues to file before coding any stage

Each open question in the design that survives into code must have a GitHub issue. File these now (before Stage 1):

- [ ] **File issue:** "Tune periodic re-resolution cadence" — reference design §"Token discovery & classification" open question 1.
- [ ] **File issue:** "Structured `counterpartyAddress` on `TransactionLeg`" — design §"Open questions" 2.
- [ ] **File issue:** "Internal-transaction reconciliation hint on OP/Base" — design §"Open questions" 3.
- [ ] **File issue:** "Multi-recipient airdrop linking UX" — design §"Open questions" 4.
- [ ] **File issue:** "Optimistic deduper before persistence" — design §"Open questions" 5.

Save the issue numbers in `.agent-tmp/crypto-wallet-issue-refs.txt` for use by the `TODO(#N)` references throughout the stages.

---

# Stage 1 — Foundation: domain types + schema

**Goal:** Land all new domain types (`AccountType.crypto`, `WalletSyncState`, `WalletSyncError`, `TokenPricingStatus`), extend `Account` (`walletAddress`, `chainId`) and `TransactionLeg` (`externalId`), update CloudKit schema (regen via `cktool`), and add the GRDB migration. **Zero behavioural changes** — no new sync, no new UI, no aggregation paths use the new state yet. This stage is a pure plumbing PR.

**Branch:** `feat/crypto-wallet-foundation`
**PR title:** `feat(crypto): foundation — domain types + schema for wallet auto-import`

**Files:**
- Create: `Domain/Models/WalletSyncState.swift`
- Create: `Domain/Models/WalletSyncError.swift`
- Create: `Domain/Models/TokenPricingStatus.swift`
- Create: `Domain/Repositories/WalletSyncStateRepository.swift`
- Modify: `Domain/Models/Account.swift` — add `walletAddress`, `chainId`, codable mapping; isolate `AccountType.crypto`.
- Modify: `Domain/Models/TransactionLeg.swift` — add `externalId` grouped with `let` identity fields.
- Modify: `Domain/Models/CryptoRegistration.swift` — add `var pricingStatus: TokenPricingStatus`; default-`.priced` for legacy decode.
- Modify: `Domain/Repositories/BackendProvider.swift` — add `walletSyncState: any WalletSyncStateRepository`.
- Modify: `CloudKit/schema.ckdb` — add `walletAddress`, `chainId` to `Account` record; add `externalId` to `TransactionLeg` record; add `pricingStatus` to the instrument-registry record.
- Run `just generate` — regenerates `Backends/CloudKit/Sync/Generated/*Fields.swift` etc.
- Modify: `Backends/GRDB/Migration/<NewMigration>.swift` — register a new GRDB migration adding `wallet_sync_state` table, `external_id` column on the leg row, `wallet_address` / `chain_id` columns on the account row, `pricing_status` column on the instrument-registry row.
- Modify: `Backends/GRDB/Records/AccountRow*.swift` — encode/decode the new fields; defensive default for unknown `type` strings.
- Modify: `Backends/GRDB/Records/TransactionLegRow*.swift` — encode/decode `external_id`.
- Modify: `Backends/GRDB/Records/InstrumentRow+Mapping.swift` — encode/decode `pricing_status`.
- Create: `Backends/GRDB/Repositories/GRDBWalletSyncStateRepository.swift`
- Create: `MoolahTests/Support/InMemoryWalletSyncStateRepository.swift`
- Modify: `App/ProfileSession+CloudKitBackendBuild.swift` (or wherever `BackendProvider` is constructed) — wire in `walletSyncState`.
- Test: `MoolahTests/Domain/AccountTypeTests.swift` — defensive decode + `isInvestmentLike`.
- Test: `MoolahTests/Domain/AccountTests.swift` — round-trip with crypto fields; nil-when-non-crypto.
- Test: `MoolahTests/Domain/TransactionLegTests.swift` — round-trip with `externalId`.
- Test: `MoolahTests/Domain/CryptoRegistrationTests.swift` — `pricingStatus` default + decode.
- Test: `MoolahTests/Domain/WalletSyncStateTests.swift` — round-trip + structured error.
- Test: `MoolahTests/Backends/GRDB/GRDBWalletSyncStateRepositoryTests.swift` — CRUD + load-all + idempotent delete.
- Test: `MoolahTests/Backends/GRDB/Migration<N>Tests.swift` — migration applies cleanly to a fresh DB and to a representative pre-migration DB.

### Tasks

- [ ] **Step 1: Read the reference docs.** `CLAUDE.md`, `guides/DATABASE_SCHEMA_GUIDE.md`, `guides/DATABASE_CODE_GUIDE.md`, `guides/SYNC_GUIDE.md`, `Domain/Models/Account.swift`, `Domain/Models/TransactionLeg.swift`, `Domain/Models/CryptoRegistration.swift`, the most-recent existing migration under `Backends/GRDB/Migration/`. (Read-only.)

- [ ] **Step 2: Create the worktree.**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native worktree add --no-track .worktrees/crypto-wallet-foundation -b feat/crypto-wallet-foundation origin/main
```

Switch all subsequent commands to that path.

- [ ] **Step 3: Write `TokenPricingStatus`.**

Create `Domain/Models/TokenPricingStatus.swift`:

```swift
import Foundation

/// How a crypto token's fiat value should be treated at aggregation.
/// Distinct from "rate unavailable" — `.unpriced` and `.spam` are intentional
/// zero contributions, not failures.
enum TokenPricingStatus: String, Codable, Sendable, CaseIterable {
  case priced     // provider mapping resolved; live price fetched
  case unpriced   // no provider mapping; fiat value is intentionally 0
  case spam       // user-hidden / Alchemy-flagged spam; fiat value is 0 and UI hides
}
```

- [ ] **Step 4: Write `WalletSyncError`.**

Create `Domain/Models/WalletSyncError.swift`:

```swift
import Foundation

/// Structured outcome of a failed wallet sync cycle. Stored in `WalletSyncState`
/// so the `CryptoSyncStore` can format it for display without coupling the
/// domain model to localised strings.
enum WalletSyncError: Codable, Sendable, Hashable {
  case missingApiKey
  case invalidApiKey
  case rateLimited(retryAfter: Date?)
  case network(underlyingDescription: String)
  case providerMalformedResponse(stage: String)
}
```

- [ ] **Step 5: Write `WalletSyncState`.**

Create `Domain/Models/WalletSyncState.swift`:

```swift
import Foundation

/// Per-device sync checkpoint for a wallet account. NOT synced cross-device —
/// each device tracks its own Alchemy-fetch progress so a restored-from-backup
/// device re-fetches from `lastSyncedBlockNumber - 32` rather than trusting a
/// stale shared checkpoint.
///
/// `id` doubles as the account UUID for `Identifiable` consumers.
struct WalletSyncState: Codable, Sendable, Identifiable, Hashable {
  let id: UUID
  var lastSyncedBlockNumber: UInt64
  var lastSyncedAt: Date
  var lastError: WalletSyncError?
}
```

- [ ] **Step 6: Write the failing tests for the new domain models.**

Create `MoolahTests/Domain/WalletSyncStateTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("WalletSyncState")
struct WalletSyncStateTests {
  @Test func roundTripsViaCodable() throws {
    let state = WalletSyncState(
      id: UUID(),
      lastSyncedBlockNumber: 19_500_000,
      lastSyncedAt: Date(timeIntervalSince1970: 1_700_000_000),
      lastError: .rateLimited(retryAfter: Date(timeIntervalSince1970: 1_700_000_300))
    )
    let data = try JSONEncoder().encode(state)
    let decoded = try JSONDecoder().decode(WalletSyncState.self, from: data)
    #expect(decoded == state)
  }

  @Test func defaultsToNilError() {
    let state = WalletSyncState(
      id: UUID(),
      lastSyncedBlockNumber: 0,
      lastSyncedAt: Date(timeIntervalSince1970: 0),
      lastError: nil
    )
    #expect(state.lastError == nil)
  }
}
```

Run: `just test WalletSyncStateTests 2>&1 | tee .agent-tmp/stage1-test.txt`
Expected: tests fail to compile (the type doesn't exist yet — actually it does from Step 5; this test should now pass).

If they pass, proceed. If they fail to compile, fix the type. (TDD-strict callers: the type was created in Step 5 to keep the file count manageable; the test verifies its contract.)

- [ ] **Step 7: Tests for `TokenPricingStatus`.**

Create `MoolahTests/Domain/TokenPricingStatusTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("TokenPricingStatus")
struct TokenPricingStatusTests {
  @Test func encodesAsLowercaseString() throws {
    let encoded = try JSONEncoder().encode(TokenPricingStatus.unpriced)
    #expect(String(data: encoded, encoding: .utf8) == "\"unpriced\"")
  }

  @Test func decodesKnownStrings() throws {
    let priced = try JSONDecoder().decode(TokenPricingStatus.self, from: Data("\"priced\"".utf8))
    let unpriced = try JSONDecoder().decode(TokenPricingStatus.self, from: Data("\"unpriced\"".utf8))
    let spam = try JSONDecoder().decode(TokenPricingStatus.self, from: Data("\"spam\"".utf8))
    #expect(priced == .priced)
    #expect(unpriced == .unpriced)
    #expect(spam == .spam)
  }
}
```

Run: `just test TokenPricingStatusTests`
Expected: PASS.

- [ ] **Step 8: Add `AccountType.crypto` and `isInvestmentLike`.**

Modify `Domain/Models/Account.swift`. Replace the existing `enum AccountType` with:

```swift
enum AccountType: String, Codable, Sendable, CaseIterable {
  case bank
  case creditCard = "cc"
  case asset
  case investment
  case crypto

  var isCurrent: Bool {
    self == .bank || self == .asset || self == .creditCard
  }

  /// Whether this type should be treated as an investment account for sidebar
  /// grouping and any query that filters investments. `true` for `.investment`
  /// and `.crypto`.
  var isInvestmentLike: Bool {
    self == .investment || self == .crypto
  }

  var displayName: String {
    switch self {
    case .bank: return "Bank Account"
    case .creditCard: return "Credit Card"
    case .asset: return "Asset"
    case .investment: return "Investment"
    case .crypto: return "Crypto Wallet"
    }
  }
}
```

- [ ] **Step 9: Add `Account.walletAddress` and `Account.chainId`.**

In the same file, extend `Account`:

```swift
struct Account: Codable, Sendable, Identifiable, Hashable, Comparable {
  let id: UUID
  var name: String
  var type: AccountType
  var instrument: Instrument
  var positions: [Position]
  var position: Int
  var isHidden: Bool
  /// `0x…` lowercased wallet address. Required when `type == .crypto`.
  var walletAddress: String?
  /// EVM chain ID (1 = Ethereum, 10 = OP, 8453 = Base, 137 = Polygon).
  /// Required when `type == .crypto`.
  var chainId: Int?

  init(
    id: UUID = UUID(),
    name: String,
    type: AccountType,
    instrument: Instrument,
    positions: [Position] = [],
    position: Int = 0,
    isHidden: Bool = false,
    walletAddress: String? = nil,
    chainId: Int? = nil
  ) {
    self.id = id
    self.name = name
    self.type = type
    self.instrument = instrument
    self.positions = positions
    self.position = position
    self.isHidden = isHidden
    self.walletAddress = walletAddress
    self.chainId = chainId
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case name
    case type
    case instrument
    case position
    case isHidden = "hidden"
    case walletAddress
    case chainId
  }
```

Update the `init(from:)`, `encode(to:)`, `==`, and `hash(into:)` implementations to include the two new fields. Use `decodeIfPresent` for `walletAddress` and `chainId` so legacy rows decode with `nil`.

- [ ] **Step 10: Tests for `AccountType` defensive decode + `isInvestmentLike`.**

Create `MoolahTests/Domain/AccountTypeTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("AccountType")
struct AccountTypeTests {
  @Test func cryptoAndInvestmentBothInvestmentLike() {
    #expect(AccountType.crypto.isInvestmentLike)
    #expect(AccountType.investment.isInvestmentLike)
    #expect(!AccountType.bank.isInvestmentLike)
    #expect(!AccountType.creditCard.isInvestmentLike)
    #expect(!AccountType.asset.isInvestmentLike)
  }

  @Test func cryptoIsNotIsCurrent() {
    #expect(!AccountType.crypto.isCurrent)
  }

  @Test func unknownStringDecodesAsAssetWithWarning() throws {
    // RawRepresentable enums fail decode on unknown raw values by default.
    // The defensive fallback for unknown account types is implemented in the
    // RECORD-LAYER decoder (AccountRow), not on the domain enum itself.
    // This test asserts the domain default — that the enum decode does throw —
    // so the record-layer test can be the single source of fallback truth.
    let json = Data("\"future-type\"".utf8)
    #expect(throws: DecodingError.self) {
      _ = try JSONDecoder().decode(AccountType.self, from: json)
    }
  }
}
```

Run: `just test AccountTypeTests`
Expected: PASS.

- [ ] **Step 11: Tests for `Account` round-trip with crypto fields.**

Create `MoolahTests/Domain/AccountTests.swift` (or extend if it exists):

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("Account")
struct AccountTests {
  @Test func cryptoAccountRoundTripsViaCodable() throws {
    let account = Account(
      id: UUID(),
      name: "Hardware Wallet — Ethereum",
      type: .crypto,
      instrument: Instrument.crypto(
        chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18),
      positions: [],
      position: 7,
      isHidden: false,
      walletAddress: "0x" + String(repeating: "a", count: 40),
      chainId: 1
    )
    let data = try JSONEncoder().encode(account)
    let decoded = try JSONDecoder().decode(Account.self, from: data)
    #expect(decoded.walletAddress == account.walletAddress)
    #expect(decoded.chainId == account.chainId)
    #expect(decoded.type == .crypto)
  }

  @Test func nonCryptoAccountOmitsWalletFields() throws {
    let account = Account(
      id: UUID(),
      name: "Cheque",
      type: .bank,
      instrument: .AUD
    )
    #expect(account.walletAddress == nil)
    #expect(account.chainId == nil)
    let data = try JSONEncoder().encode(account)
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(json["walletAddress"] == nil)
    #expect(json["chainId"] == nil)
  }

  @Test func legacyAccountWithoutWalletFieldsDecodesWithNil() throws {
    let json = """
      {"id":"\(UUID().uuidString)","name":"Old","type":"bank","instrument":{"id":"AUD","kind":"fiatCurrency","name":"AUD","decimals":2},"position":0,"hidden":false}
      """.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(Account.self, from: json)
    #expect(decoded.walletAddress == nil)
    #expect(decoded.chainId == nil)
  }
}
```

Run: `just test AccountTests`
Expected: PASS.

- [ ] **Step 12: Add `TransactionLeg.externalId`.**

Modify `Domain/Models/TransactionLeg.swift`:

```swift
import Foundation

struct TransactionLeg: Codable, Sendable, Hashable {
  let accountId: UUID?
  let instrument: Instrument
  let quantity: Decimal
  let externalId: String?
  var type: TransactionType
  var categoryId: UUID?
  var earmarkId: UUID?

  init(
    accountId: UUID?,
    instrument: Instrument,
    quantity: Decimal,
    type: TransactionType,
    categoryId: UUID? = nil,
    earmarkId: UUID? = nil,
    externalId: String? = nil
  ) {
    self.accountId = accountId
    self.instrument = instrument
    self.quantity = quantity
    self.externalId = externalId
    self.type = type
    self.categoryId = categoryId
    self.earmarkId = earmarkId
  }

  /// Convenience: the quantity as an InstrumentAmount.
  var amount: InstrumentAmount {
    InstrumentAmount(quantity: quantity, instrument: instrument)
  }
}
```

- [ ] **Step 13: Tests for `TransactionLeg.externalId`.**

Create `MoolahTests/Domain/TransactionLegTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("TransactionLeg")
struct TransactionLegTests {
  @Test func externalIdRoundTrips() throws {
    let leg = TransactionLeg(
      accountId: UUID(),
      instrument: .AUD,
      quantity: 100,
      type: .income,
      externalId: "0xabcdef"
    )
    let data = try JSONEncoder().encode(leg)
    let decoded = try JSONDecoder().decode(TransactionLeg.self, from: data)
    #expect(decoded.externalId == "0xabcdef")
  }

  @Test func legacyLegWithoutExternalIdDecodesWithNil() throws {
    let json = """
      {"accountId":"\(UUID().uuidString)","instrument":{"id":"AUD","kind":"fiatCurrency","name":"AUD","decimals":2},"quantity":"100","type":"income"}
      """.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(TransactionLeg.self, from: json)
    #expect(decoded.externalId == nil)
  }
}
```

Run: `just test TransactionLegTests`
Expected: PASS.

- [ ] **Step 14: Add `pricingStatus` to `CryptoRegistration`.**

Modify `Domain/Models/CryptoRegistration.swift`:

Replace the `struct CryptoRegistration` with:

```swift
struct CryptoRegistration: Codable, Sendable, Hashable, Identifiable {
  let instrument: Instrument
  let mapping: CryptoProviderMapping
  /// How aggregation should treat this token's fiat value. Distinct from
  /// "rate unavailable" — `.unpriced` and `.spam` are intentionally zero,
  /// not errors.
  var pricingStatus: TokenPricingStatus

  init(
    instrument: Instrument,
    mapping: CryptoProviderMapping,
    pricingStatus: TokenPricingStatus = .priced
  ) {
    self.instrument = instrument
    self.mapping = mapping
    self.pricingStatus = pricingStatus
  }

  var id: String { instrument.id }

  private enum CodingKeys: String, CodingKey {
    case instrument
    case mapping
    case pricingStatus
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.instrument = try container.decode(Instrument.self, forKey: .instrument)
    self.mapping = try container.decode(CryptoProviderMapping.self, forKey: .mapping)
    self.pricingStatus = try container.decodeIfPresent(
      TokenPricingStatus.self, forKey: .pricingStatus) ?? .priced
  }
}
```

Keep the existing `static let builtInPresets: [CryptoRegistration]` as-is — they'll all default to `.priced` since they don't pass a `pricingStatus`.

- [ ] **Step 15: Tests for `CryptoRegistration.pricingStatus` default.**

Create `MoolahTests/Domain/CryptoRegistrationTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("CryptoRegistration")
struct CryptoRegistrationTests {
  @Test func presetsDefaultToPriced() {
    for preset in CryptoRegistration.builtInPresets {
      #expect(preset.pricingStatus == .priced)
    }
  }

  @Test func legacyRegistrationDecodesAsPriced() throws {
    let json = """
      {"instrument":{"id":"1:native","kind":"cryptoToken","name":"Ethereum","decimals":18,"ticker":"ETH","chainId":1},"mapping":{"instrumentId":"1:native","coingeckoId":"ethereum","cryptocompareSymbol":"ETH","binanceSymbol":"ETHUSDT"}}
      """.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(CryptoRegistration.self, from: json)
    #expect(decoded.pricingStatus == .priced)
  }

  @Test func explicitStatusRoundTrips() throws {
    let registration = CryptoRegistration(
      instrument: Instrument.crypto(
        chainId: 1, contractAddress: "0x1234567890abcdef1234567890abcdef12345678",
        symbol: "WTF", name: "Spam Token", decimals: 18),
      mapping: CryptoProviderMapping(
        instrumentId: "1:0x1234567890abcdef1234567890abcdef12345678",
        coingeckoId: nil, cryptocompareSymbol: nil, binanceSymbol: nil),
      pricingStatus: .spam
    )
    let data = try JSONEncoder().encode(registration)
    let decoded = try JSONDecoder().decode(CryptoRegistration.self, from: data)
    #expect(decoded.pricingStatus == .spam)
  }
}
```

Run: `just test CryptoRegistrationTests`
Expected: PASS.

- [ ] **Step 16: Define the repository protocol.**

Create `Domain/Repositories/WalletSyncStateRepository.swift`:

```swift
import Foundation

/// Per-device sync checkpoints for crypto wallet accounts.
///
/// Why this is a domain concern: `CryptoSyncStore` decides which accounts
/// to sync at launch (`loadAll`) and how far back to refetch from Alchemy
/// (`load`). Implementations are GRDB-local — these checkpoints are NOT
/// synced cross-device, so a restored-from-backup device falls back to a
/// genesis-style refetch rather than trusting a stale shared checkpoint.
protocol WalletSyncStateRepository: Sendable {
  /// Why: at app launch the store needs to know which accounts are stale
  /// (`lastSyncedAt > 24h ago`). Returning every checkpoint avoids N round
  /// trips through `load(accountId:)`.
  func loadAll() async throws -> [WalletSyncState]
  /// Why: per-sync-cycle, the engine reads `lastSyncedBlockNumber` so the
  /// reorg window starts at `block - 32`. `nil` means "never synced — fetch
  /// from genesis or chain config's seed block".
  func load(accountId: UUID) async throws -> WalletSyncState?
  /// Why: the engine writes the checkpoint after every cycle (success or
  /// failure — failures populate `lastError` so the UI can surface staleness
  /// without losing the prior block-number checkpoint). Upsert on `id`.
  func save(_ state: WalletSyncState) async throws
  /// Why: account deletion races with sync; if the engine writes a row right
  /// after the account is deleted, the next account-deletion path needs to
  /// idempotently clean up — succeeds with no effect when no row exists.
  func delete(accountId: UUID) async throws
}
```

- [ ] **Step 17: Add `walletSyncState` to `BackendProvider`.**

Modify `Domain/Repositories/BackendProvider.swift`:

```swift
protocol BackendProvider: Sendable {
  var auth: any AuthProvider { get }
  var accounts: any AccountRepository { get }
  var transactions: any TransactionRepository { get }
  var categories: any CategoryRepository { get }
  var earmarks: any EarmarkRepository { get }
  var analysis: any AnalysisRepository { get }
  var investments: any InvestmentRepository { get }
  var conversionService: any InstrumentConversionService { get }
  var csvImportProfiles: any CSVImportProfileRepository { get }
  var importRules: any ImportRuleRepository { get }
  var walletSyncState: any WalletSyncStateRepository { get }
}
```

This will break every concrete `BackendProvider` implementation. Find them with `git grep -l "BackendProvider" --include="*.swift"` and add a stub `walletSyncState` returning an in-memory implementation (Step 19) for tests / previews; production wiring happens in Step 27.

- [ ] **Step 18: Write the in-memory test repository.**

Create `MoolahTests/Support/InMemoryWalletSyncStateRepository.swift`. Follows the project's established `@unchecked Sendable` + `NSLock` pattern for test-target repositories (matches `GRDBAccountRepository`'s production-side justification doc-comment style — see DATABASE_CODE_GUIDE §2 False Positives).

```swift
import Foundation

@testable import Moolah

/// **`@unchecked Sendable` justification.** `states` is a Swift `Dictionary`,
/// not Sendable on its own. `lock` is an `NSLock` and mediates every mutation
/// and read — every method body wraps its access in `lock.withLock`. No state
/// escapes the lock; no mutation happens outside it. Pattern matches
/// `GRDBAccountRepository`'s justification.
final class InMemoryWalletSyncStateRepository: WalletSyncStateRepository, @unchecked Sendable {
  private let lock = NSLock()
  private var states: [UUID: WalletSyncState] = [:]

  func loadAll() async throws -> [WalletSyncState] {
    lock.withLock { Array(states.values) }
  }

  func load(accountId: UUID) async throws -> WalletSyncState? {
    lock.withLock { states[accountId] }
  }

  func save(_ state: WalletSyncState) async throws {
    lock.withLock { states[state.id] = state }
  }

  func delete(accountId: UUID) async throws {
    lock.withLock { states[accountId] = nil }
  }
}
```

Wire this into `TestBackend` — extend the test backend's stub `BackendProvider` to expose an `InMemoryWalletSyncStateRepository`.

- [ ] **Step 19: Update `CloudKit/schema.ckdb` for the new fields.**

Run `just generate` after edits.

Add to the existing `Account` record type:

```
    walletAddress      STRING        QUERYABLE
    chainId            INT64         QUERYABLE
```

Add to the existing `TransactionLeg` record type:

```
    externalId         STRING        QUERYABLE
```

Add to the existing instrument-registry record (inspect `schema.ckdb` for the exact name — likely `Instrument` or `CryptoRegistration`):

```
    pricingStatus      STRING
```

After saving the file, run:

```bash
just generate
```

Verify diff in `Backends/CloudKit/Sync/Generated/` — the generated `*Fields.swift` structs should now include the new fields.

- [ ] **Step 20: Update `AccountRow` for `walletAddress` / `chainId`.**

Inspect `Backends/GRDB/Records/AccountRow.swift`. Stored properties live in the struct body (extension stored properties are illegal Swift). Add to the struct:

```swift
struct AccountRow {
  static let databaseTableName = "account"

  enum Columns: String, ColumnExpression, CaseIterable {
    case id
    case recordName = "record_name"
    case name
    case type
    case instrumentId = "instrument_id"
    case position
    case isHidden = "is_hidden"
    case encodedSystemFields = "encoded_system_fields"
    case walletAddress = "wallet_address"     // NEW
    case chainId = "chain_id"                  // NEW
  }

  enum CodingKeys: String, CodingKey {
    case id
    case recordName = "record_name"
    case name
    case type
    case instrumentId = "instrument_id"
    case position
    case isHidden = "is_hidden"
    case encodedSystemFields = "encoded_system_fields"
    case walletAddress = "wallet_address"     // NEW
    case chainId = "chain_id"                  // NEW
  }

  var id: UUID
  var recordName: String
  var name: String
  var type: String
  var instrumentId: String
  var position: Int
  var isHidden: Bool
  var encodedSystemFields: Data?
  var walletAddress: String?     // NEW
  var chainId: Int?              // NEW
}
```

Then update the AccountRow → Account domain mapping (search for `extension AccountRow` and the `toDomain` / `init(domain:)` paths) to round-trip the two new fields. Use `Codable`'s `decodeIfPresent` semantics so legacy rows decode with `nil`.

**Defensive decode for unknown `type` strings.** `AccountRow.type` is a raw `String`; the `String → AccountType` conversion happens in the `toDomain` mapping. Update that mapping to fall back to `.asset` and emit a single `os.Logger` warning when an unrecognised type string is seen — protecting older app builds that receive a `type = "crypto"` record from a newer device.

Find the existing mapping (likely `AccountRow+Mapping.swift` or similar) and update:

```swift
private func decodeType(_ raw: String) -> AccountType {
  if let known = AccountType(rawValue: raw) { return known }
  Self.logger.warning(
    "Unknown account type \(raw, privacy: .public) — falling back to .asset")
  return .asset
}
```

Add a unit test:

`MoolahTests/Backends/GRDB/AccountRowDefensiveDecodeTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("AccountRow defensive decode")
struct AccountRowDefensiveDecodeTests {
  @Test func unknownTypeStringMapsToAsset() throws {
    let row = AccountRow(
      id: UUID(), recordName: "rec", name: "Future",
      type: "future-account-type-from-newer-build",
      instrumentId: "AUD", position: 0, isHidden: false,
      encodedSystemFields: nil, walletAddress: nil, chainId: nil)
    let domain = try row.toDomain(instrument: .AUD)
    #expect(domain.type == .asset)
  }

  @Test func knownTypeStringsDecodeUnchanged() throws {
    for type in AccountType.allCases {
      let row = AccountRow(
        id: UUID(), recordName: "rec", name: "Test",
        type: type.rawValue, instrumentId: "AUD", position: 0, isHidden: false,
        encodedSystemFields: nil, walletAddress: nil, chainId: nil)
      let domain = try row.toDomain(instrument: .AUD)
      #expect(domain.type == type)
    }
  }
}
```

The warning-emission assertion is deferred until the project has an `os.Logger` capture seam. Before merging this stage, **file an issue**: "Wire `os.Logger` capture for tests" and add a comment to the test:

```swift
// TODO(#N): assert exactly one warning emitted via os.Logger capture —
// https://github.com/ajsutton/moolah-native/issues/N
```

Use the issue number filed at the head of this plan (Open issues to file before coding).

- [ ] **Step 21: Update `TransactionLegRow` for `externalId`.**

Inspect `Backends/GRDB/Records/TransactionLegRow.swift` (and `TransactionLegRow+Mapping.swift` if separate). Add the new column and stored property in the struct body, plus the matching `Columns` and `CodingKeys` cases. Round-trip in the domain mapping with `decodeIfPresent` semantics for legacy rows. Same pattern as Step 20.

- [ ] **Step 22: Update `InstrumentRow` for `pricingStatus`.**

Inspect `Backends/GRDB/Records/InstrumentRow.swift` and `InstrumentRow+Mapping.swift`. The cryptoMapping path produces `CryptoRegistration` instances. Three changes:

1. Add `pricingStatus: String?` to the `InstrumentRow` struct body (with matching `Columns.pricingStatus = "pricing_status"` and `CodingKeys.pricingStatus = "pricing_status"`).
2. Update `InstrumentRow.cryptoMapping(...)` (or wherever `CryptoRegistration` is constructed) to read the column and pass it via the new `pricingStatus:` initializer parameter, defaulting to `.priced` for legacy `nil` values.
3. Update the inverse — the path that writes a `CryptoRegistration` back to a row — to populate `pricing_status` from the registration.

The cross-device merge handler that gates inbound writes (`.spam` always wins, etc.) is added in Stage 3 — for now, every existing row maps to `.priced` and writes round-trip without conflict logic.

- [ ] **Step 23: Add the GRDB migration.**

**Pre-flight:** confirm none of the new columns already exist in any prior migration (the schema-review identified a column-name collision risk):

```bash
git -C <worktree> grep -nE "wallet_address|external_id|wallet_sync_state" Backends/GRDB/ProfileSchema*.swift
git -C <worktree> grep -nE "ADD COLUMN .*chain_id" Backends/GRDB/ProfileSchema*.swift
```

Expected: zero matches in `ProfileSchema*.swift` for `wallet_address`, `external_id`, `wallet_sync_state`. (The existing `chain_id` on the `instrument` table is a *different* table — adding `chain_id` to `account` is a new column.)

Find the most-recent migration under `Backends/GRDB/ProfileSchema*.swift` to copy its shape (note the `vN_snake_case` ID convention — the migration is `v6_add_crypto_wallet_fields`, not PascalCase). Create `Backends/GRDB/ProfileSchema+CryptoWalletFields.swift` with:

```swift
import Foundation
import GRDB

extension ProfileSchema {
  /// Migration v6: adds Account wallet metadata, TransactionLeg externalId
  /// (with a partial-unique dedup index), Instrument pricingStatus column,
  /// and the per-device wallet_sync_state table.
  ///
  /// Retention: wallet_sync_state rows are application-scoped to their account.
  /// `AccountRepository.delete(_:)` must also call
  /// `WalletSyncStateRepository.delete(accountId:)` — there is no FK constraint
  /// because wallet_sync_state is excluded from CKSyncEngine and the FK would
  /// add cross-table ordering constraints CKSyncEngine doesn't know to honour.
  /// Block-number data is cheap; no time-based purge.
  static func registerV6AddCryptoWalletFields(in migrator: inout DatabaseMigrator) {
    migrator.registerMigration("v6_add_crypto_wallet_fields") { db in
      // 1. Account: wallet_address, chain_id (additive, optional, no CHECK
      //    needed — both are free-form data validated at the form layer).
      try db.alter(table: "account") { table in
        table.add(column: "wallet_address", .text)
        table.add(column: "chain_id", .integer)
      }

      // 2. TransactionLeg: external_id + a PARTIAL UNIQUE index that enforces
      //    per-(account, external_id) uniqueness for non-NULL external_ids.
      //    Same on-chain hash on different accounts is allowed (cross-account
      //    transfer); same hash on the same account is a duplicate import that
      //    must be rejected at the DB layer (defence-in-depth — application
      //    dedup is the primary check). NULL external_ids are excluded
      //    (existing rows and manual transactions).
      try db.alter(table: "transaction_leg") { table in
        table.add(column: "external_id", .text)
      }
      try db.create(
        index: "idx_transaction_leg_account_external",
        on: "transaction_leg",
        columns: ["account_id", "external_id"],
        options: [.unique, .ifNotExists],
        condition: Column("external_id") != nil)

      // 3. Instrument: pricing_status with CHECK constraint pinning the enum
      //    raw values. Default 'priced' so existing rows behave unchanged.
      try db.alter(table: "instrument") { table in
        table.add(column: "pricing_status", .text)
          .defaults(to: "priced")
          .check(sql: "pricing_status IN ('priced', 'unpriced', 'spam')")
      }

      // 4. wallet_sync_state: per-device sync checkpoint. STRICT for type
      //    enforcement. account_id is BLOB to match account.id (UUID-as-BLOB
      //    in this project's GRDB convention). last_error_json validated by
      //    json_valid() per DATABASE_SCHEMA_GUIDE §3.
      try db.create(
        table: "wallet_sync_state",
        options: [.ifNotExists, .strict]
      ) { table in
        table.column("account_id", .blob).primaryKey()
        table.column("last_synced_block_number", .integer).notNull()
        table.column("last_synced_at", .datetime).notNull()
        table.column("last_error_json", .text)
          .check(sql: "last_error_json IS NULL OR json_valid(last_error_json)")
      }
    }
  }
}
```

Then register this migration in `ProfileSchema.migrator` (find the existing `registerMigration` chain in `ProfileSchema.swift` around line 49). Bump `ProfileSchema.version` to `6` if that constant exists.

**Verify** the column type for `account.id` in `Backends/GRDB/ProfileSchema+CoreFinancialGraph.swift` before committing — the prescription assumes BLOB. If the project actually uses TEXT for UUIDs (some GRDB setups do), change `account_id` in `wallet_sync_state` to match. Run:

```bash
grep -A2 "table: \"account\"" Backends/GRDB/ProfileSchema+CoreFinancialGraph.swift | grep -E "id\\.|column.*id"
```

- [ ] **Step 24: Tests for the migration.**

Create `MoolahTests/Backends/GRDB/V6AddCryptoWalletFieldsMigrationTests.swift`:

```swift
import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("v6_add_crypto_wallet_fields migration")
struct V6AddCryptoWalletFieldsMigrationTests {
  @Test func appliesCleanlyToFreshDatabase() throws {
    let queue = try DatabaseQueue()
    var migrator = ProfileSchema.migrator
    try migrator.migrate(queue)

    try queue.read { db in
      let accountColumns = try db.columns(in: "account").map(\.name)
      #expect(accountColumns.contains("wallet_address"))
      #expect(accountColumns.contains("chain_id"))

      let legColumns = try db.columns(in: "transaction_leg").map(\.name)
      #expect(legColumns.contains("external_id"))

      let instrumentColumns = try db.columns(in: "instrument").map(\.name)
      #expect(instrumentColumns.contains("pricing_status"))

      #expect(try db.tableExists("wallet_sync_state"))

      // Partial unique dedup index exists.
      let indexes = try db.indexes(on: "transaction_leg").map(\.name)
      #expect(indexes.contains("idx_transaction_leg_account_external"))

      // STRICT enforcement on wallet_sync_state.
      let walletStateInfo = try Row.fetchAll(db, sql: """
        SELECT * FROM sqlite_master WHERE type='table' AND name='wallet_sync_state'
        """)
      let createSQL = try #require(walletStateInfo.first?["sql"] as? String)
      #expect(createSQL.uppercased().contains("STRICT"))
    }
  }

  @Test func partialUniqueIndexRejectsDuplicateExternalIdOnSameAccount() throws {
    let queue = try DatabaseQueue()
    var migrator = ProfileSchema.migrator
    try migrator.migrate(queue)

    let accountId = UUID()
    try queue.write { db in
      // Seed an account row + transaction + first leg with externalId.
      // (Use the project's actual seeding helpers — this is illustrative;
      // adapt to whatever the existing test pattern uses.)
      // Then attempt a second leg with the same (account_id, external_id):
      let firstInsert: Result<Void, Error> = Result {
        try db.execute(sql: """
          INSERT INTO transaction_leg
          (id, transaction_id, account_id, instrument_id, quantity, type, external_id)
          VALUES (?, ?, ?, 'AUD', '100', 'income', '0xabc')
          """, arguments: [UUID().uuidString, UUID().uuidString, accountId.uuidString])
      }
      _ = try firstInsert.get()

      let duplicateInsert: () throws -> Void = {
        try db.execute(sql: """
          INSERT INTO transaction_leg
          (id, transaction_id, account_id, instrument_id, quantity, type, external_id)
          VALUES (?, ?, ?, 'AUD', '50', 'income', '0xabc')
          """, arguments: [UUID().uuidString, UUID().uuidString, accountId.uuidString])
      }
      #expect(throws: DatabaseError.self) { try duplicateInsert() }
    }
  }

  @Test func pricingStatusCheckConstraintRejectsUnknownValue() throws {
    let queue = try DatabaseQueue()
    var migrator = ProfileSchema.migrator
    try migrator.migrate(queue)

    try queue.write { db in
      let badStatus = {
        try db.execute(sql: """
          UPDATE instrument SET pricing_status = 'bogus' WHERE id = 'AUD'
          """)
      }
      // The CHECK fires on UPDATE / INSERT — verify we get a constraint error.
      // (If 'AUD' isn't seeded in this test fixture, INSERT a row first.)
      #expect(throws: DatabaseError.self) { try badStatus() }
    }
  }
}
```

The exact column lists in the seed INSERT statements above must be aligned with the actual schema (use `git -C <worktree> grep -n "CREATE TABLE transaction_leg" Backends/GRDB/`). The test pattern is the load-bearing piece — concrete fixtures may need adjustment.

Run: `just test V6AddCryptoWalletFieldsMigrationTests`
Expected: PASS.

- [ ] **Step 25: Implement `GRDBWalletSyncStateRepository` — three files per project convention.**

DATABASE_CODE_GUIDE §3 splits records into three files: `Backends/GRDB/Records/<Row>.swift` (struct + GRDB conformance), `Backends/GRDB/Records/<Row>+Mapping.swift` (`toDomain` / `init(domain:)`), and `Backends/GRDB/Repositories/GRDB<Name>Repository.swift` (the repository). Match this here.

**File 1 — `Backends/GRDB/Records/WalletSyncStateRow.swift`:**

```swift
import Foundation
import GRDB

/// One row in the `wallet_sync_state` table — per-device sync checkpoints
/// for crypto wallet accounts. NOT synced cross-device (see DATABASE_SCHEMA
/// migration v6 retention notes).
///
/// `account_id` is `BLOB` matching `account.id`; UUIDs flow as `Data` at the
/// SQLite boundary and as `UUID` in the domain.
struct WalletSyncStateRow {
  static let databaseTableName = "wallet_sync_state"

  enum Columns: String, ColumnExpression, CaseIterable {
    case accountId = "account_id"
    case lastSyncedBlockNumber = "last_synced_block_number"
    case lastSyncedAt = "last_synced_at"
    case lastErrorJson = "last_error_json"
  }

  enum CodingKeys: String, CodingKey {
    case accountId = "account_id"
    case lastSyncedBlockNumber = "last_synced_block_number"
    case lastSyncedAt = "last_synced_at"
    case lastErrorJson = "last_error_json"
  }

  /// Stored as the account's UUID. `WalletSyncError` is JSON-encoded into
  /// `lastErrorJson` rather than flattened to columns because it has
  /// associated values; the table is local-only and never queried by error
  /// shape, so the JSON column is fine per DATABASE_CODE_GUIDE §3.
  var accountId: UUID
  var lastSyncedBlockNumber: Int64
  var lastSyncedAt: Date
  var lastErrorJson: String?
}

extension WalletSyncStateRow: Codable {}
extension WalletSyncStateRow: Sendable {}
extension WalletSyncStateRow: FetchableRecord {}
extension WalletSyncStateRow: PersistableRecord {}
```

(GRDB's UUID ↔ BLOB mapping is built-in via `Codable` — no manual conversion needed.)

**File 2 — `Backends/GRDB/Records/WalletSyncStateRow+Mapping.swift`:**

```swift
import Foundation

extension WalletSyncStateRow {
  /// Converts a domain `WalletSyncState` to its row representation.
  /// Throws if the structured `WalletSyncError` cannot be JSON-encoded
  /// (extremely unlikely — the type only contains `Codable` primitives).
  init(state: WalletSyncState) throws {
    self.accountId = state.id
    self.lastSyncedBlockNumber = Int64(state.lastSyncedBlockNumber)
    self.lastSyncedAt = state.lastSyncedAt
    if let error = state.lastError {
      let data = try JSONEncoder().encode(error)
      self.lastErrorJson = String(decoding: data, as: UTF8.self)
    } else {
      self.lastErrorJson = nil
    }
  }

  /// Reconstructs the domain `WalletSyncState` from this row.
  /// Throws `BackendError.dataCorrupted` if `lastErrorJson` exists but
  /// fails to decode (shouldn't happen in practice — the column has a
  /// `json_valid` CHECK and we only ever write encoded `WalletSyncError`).
  func toDomain() throws -> WalletSyncState {
    let lastError: WalletSyncError?
    if let json = lastErrorJson {
      do {
        lastError = try JSONDecoder().decode(
          WalletSyncError.self, from: Data(json.utf8))
      } catch {
        throw BackendError.dataCorrupted(
          "wallet_sync_state.last_error_json failed to decode: \(error)")
      }
    } else {
      lastError = nil
    }
    return WalletSyncState(
      id: accountId,
      lastSyncedBlockNumber: UInt64(max(0, lastSyncedBlockNumber)),
      lastSyncedAt: lastSyncedAt,
      lastError: lastError
    )
  }
}
```

(If `BackendError.dataCorrupted(_:)` doesn't exist, use the project's actual data-corruption-at-DB-boundary error type — search for "dataCorrupted" or "DatabaseError" in `Domain/Models/BackendError.swift` and adjacent files. Match the existing convention.)

**File 3 — `Backends/GRDB/Repositories/GRDBWalletSyncStateRepository.swift`:**

```swift
import Foundation
import GRDB

/// **`@unchecked Sendable` justification.** All stored properties are `let`.
/// `database` (`any DatabaseWriter`) is itself `Sendable` (GRDB protocol
/// guarantee — the queue's serial executor mediates concurrent access).
/// Pattern matches `GRDBAccountRepository`.
final class GRDBWalletSyncStateRepository: WalletSyncStateRepository, @unchecked Sendable {
  private let database: any DatabaseWriter

  init(database: any DatabaseWriter) {
    self.database = database
  }

  func loadAll() async throws -> [WalletSyncState] {
    try await database.read { db in
      try WalletSyncStateRow.fetchAll(db).map { try $0.toDomain() }
    }
  }

  func load(accountId: UUID) async throws -> WalletSyncState? {
    try await database.read { db in
      try WalletSyncStateRow
        .filter(WalletSyncStateRow.Columns.accountId == accountId)
        .fetchOne(db)?
        .toDomain()
    }
  }

  func save(_ state: WalletSyncState) async throws {
    // Single-statement GRDB upsert — atomically replaces any existing row;
    // no multi-statement rollback test required (DATABASE_CODE_GUIDE §5).
    try await database.write { db in
      try WalletSyncStateRow(state: state).save(db)
    }
  }

  func delete(accountId: UUID) async throws {
    try await database.write { db in
      _ = try WalletSyncStateRow
        .filter(WalletSyncStateRow.Columns.accountId == accountId)
        .deleteAll(db)
    }
  }
}
```

- [ ] **Step 26: Tests for `GRDBWalletSyncStateRepository`.**

Create `MoolahTests/Backends/GRDB/GRDBWalletSyncStateRepositoryTests.swift`. Uses `ProfileSchema.migrator` (the project's actual migration entry point), not an invented helper.

```swift
import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("GRDBWalletSyncStateRepository")
struct GRDBWalletSyncStateRepositoryTests {
  private func makeQueue() throws -> DatabaseQueue {
    let queue = try DatabaseQueue()
    var migrator = ProfileSchema.migrator
    try migrator.migrate(queue)
    return queue
  }

  @Test func saveAndLoadRoundTrips() async throws {
    let queue = try makeQueue()
    let repo = GRDBWalletSyncStateRepository(database: queue)
    let state = WalletSyncState(
      id: UUID(),
      lastSyncedBlockNumber: 19_500_000,
      lastSyncedAt: Date(timeIntervalSince1970: 1_700_000_000),
      lastError: nil
    )
    try await repo.save(state)
    let loaded = try await repo.load(accountId: state.id)
    #expect(loaded == state)
  }

  @Test func loadAllReturnsEverySaved() async throws {
    let queue = try makeQueue()
    let repo = GRDBWalletSyncStateRepository(database: queue)
    for i in 0..<3 {
      try await repo.save(.init(
        id: UUID(),
        lastSyncedBlockNumber: UInt64(1000 + i),
        lastSyncedAt: Date(timeIntervalSince1970: TimeInterval(i)),
        lastError: nil))
    }
    let all = try await repo.loadAll()
    #expect(all.count == 3)
  }

  @Test func errorRoundTrips() async throws {
    let queue = try makeQueue()
    let repo = GRDBWalletSyncStateRepository(database: queue)
    let state = WalletSyncState(
      id: UUID(),
      lastSyncedBlockNumber: 0,
      lastSyncedAt: Date(timeIntervalSince1970: 0),
      lastError: .invalidApiKey
    )
    try await repo.save(state)
    let loaded = try await repo.load(accountId: state.id)
    #expect(loaded?.lastError == .invalidApiKey)
  }

  @Test func deleteIsIdempotent() async throws {
    let queue = try makeQueue()
    let repo = GRDBWalletSyncStateRepository(database: queue)
    let id = UUID()
    try await repo.delete(accountId: id)
    try await repo.delete(accountId: id)
    #expect(try await repo.load(accountId: id) == nil)
  }

  @Test func saveOverwritesExistingRowAtomically() async throws {
    let queue = try makeQueue()
    let repo = GRDBWalletSyncStateRepository(database: queue)
    let id = UUID()
    let first = WalletSyncState(
      id: id, lastSyncedBlockNumber: 100,
      lastSyncedAt: Date(timeIntervalSince1970: 100), lastError: nil)
    try await repo.save(first)

    let second = WalletSyncState(
      id: id, lastSyncedBlockNumber: 200,
      lastSyncedAt: Date(timeIntervalSince1970: 200),
      lastError: .network(underlyingDescription: "boom"))
    try await repo.save(second)

    let loaded = try await repo.load(accountId: id)
    #expect(loaded?.lastSyncedBlockNumber == 200)
    #expect(loaded?.lastError == .network(underlyingDescription: "boom"))

    let all = try await repo.loadAll()
    #expect(all.count == 1)  // upsert, not duplicate
  }

  // Plan-pinning test per DATABASE_CODE_GUIDE §6: loadAll runs on the
  // app-launch hot path. A regression that adds a non-PK scan would
  // surface here.
  @Test func loadAllUsesExpectedQueryPlan() async throws {
    let queue = try makeQueue()
    try await queue.read { db in
      let plan = try Row.fetchAll(db, sql: """
        EXPLAIN QUERY PLAN SELECT * FROM wallet_sync_state
        """).map { row -> String in
          (row["detail"] as? String) ?? String(describing: row)
        }
      // wallet_sync_state has no secondary indexes; SQLite uses a SCAN over
      // the table (or USE PRIMARY KEY for a sorted scan). The point of the
      // pin is to fail loud if a future migration adds a join or sub-select
      // that we didn't intend.
      #expect(plan.contains { $0.contains("wallet_sync_state") })
      #expect(!plan.contains { $0.contains("USING TEMP B-TREE") })
    }
  }
}
```

Run: `just test GRDBWalletSyncStateRepositoryTests`
Expected: PASS.

- [ ] **Step 27: Wire `walletSyncState` into the production `BackendProvider`.**

Find the production `BackendProvider` construction (likely `App/ProfileSession+CloudKitBackendBuild.swift`). Construct a `GRDBWalletSyncStateRepository` from the same `dbWriter` everything else uses, and assign to the new property.

Verify any preview-time `BackendProvider` returns an `InMemoryWalletSyncStateRepository` for previews.

- [ ] **Step 28: Format and full test sweep.**

```bash
just format
just format-check
just test 2>&1 | tee .agent-tmp/stage1-full-test.txt
grep -i 'failed\|error:' .agent-tmp/stage1-full-test.txt | grep -v "lastError" || echo "no failures"
```

Expected: format clean, all tests pass.

If any test fails, fix in place. If `just format-check` returns non-zero, run `just format` again and re-check.

- [ ] **Step 29: Pre-PR review.**

Run these reviewer agents in parallel:
- `code-review` — the new types, repository, BackendProvider extension, file placements.
- `database-schema-review` — the GRDB migration (table creation, columns, index, defaults).
- `database-code-review` — the GRDB row mapping, repository CRUD shape.
- `sync-review` — the CloudKit schema additions, defensive AccountType decode.

For every Critical/Important/Minor finding: apply the fix. Re-run the affected agent. Repeat until clean. Do not defer findings.

- [ ] **Step 30: Commit and open PR.**

Stage specific files (avoid `git add -A`; verify `git status` first to catch any unintended files):

```bash
git -C .worktrees/crypto-wallet-foundation status

git -C .worktrees/crypto-wallet-foundation add \
  Domain/Models/AccountType+InvestmentLike.swift \
  Domain/Models/Account.swift \
  Domain/Models/TransactionLeg.swift \
  Domain/Models/CryptoRegistration.swift \
  Domain/Models/TokenPricingStatus.swift \
  Domain/Models/WalletSyncState.swift \
  Domain/Models/WalletSyncError.swift \
  Domain/Repositories/WalletSyncStateRepository.swift \
  Domain/Repositories/BackendProvider.swift \
  Backends/GRDB/Records/AccountRow.swift \
  Backends/GRDB/Records/AccountRow+Mapping.swift \
  Backends/GRDB/Records/TransactionLegRow.swift \
  Backends/GRDB/Records/TransactionLegRow+Mapping.swift \
  Backends/GRDB/Records/InstrumentRow.swift \
  Backends/GRDB/Records/InstrumentRow+Mapping.swift \
  Backends/GRDB/Records/WalletSyncStateRow.swift \
  Backends/GRDB/Records/WalletSyncStateRow+Mapping.swift \
  Backends/GRDB/Repositories/GRDBWalletSyncStateRepository.swift \
  Backends/GRDB/ProfileSchema+CryptoWalletFields.swift \
  Backends/GRDB/ProfileSchema.swift \
  Backends/CloudKit/Sync/Generated/ \
  CloudKit/schema.ckdb \
  App/ProfileSession+CloudKitBackendBuild.swift \
  MoolahTests/Domain/AccountTypeTests.swift \
  MoolahTests/Domain/AccountTests.swift \
  MoolahTests/Domain/TransactionLegTests.swift \
  MoolahTests/Domain/CryptoRegistrationTests.swift \
  MoolahTests/Domain/TokenPricingStatusTests.swift \
  MoolahTests/Domain/WalletSyncStateTests.swift \
  MoolahTests/Backends/GRDB/V6AddCryptoWalletFieldsMigrationTests.swift \
  MoolahTests/Backends/GRDB/AccountRowDefensiveDecodeTests.swift \
  MoolahTests/Backends/GRDB/GRDBWalletSyncStateRepositoryTests.swift \
  MoolahTests/Support/InMemoryWalletSyncStateRepository.swift \
  plans/2026-05-05-crypto-wallet-import-design.md \
  plans/2026-05-05-crypto-wallet-import-plan.md

# (Add any additional files surfaced by `git status` that genuinely belong
# to this stage; reject anything that doesn't.)

git -C .worktrees/crypto-wallet-foundation commit -m "$(cat <<'EOF'
feat(crypto): foundation — domain types + schema for wallet auto-import

Adds the data-model and storage primitives that subsequent stages of the
crypto wallet import build on. Zero behavioural changes — no new sync,
no new UI, nothing aggregates over the new state yet.

- AccountType.crypto + isInvestmentLike (every .investment-filtering
  query treats .crypto the same way).
- Account.walletAddress / chainId (optional; required when type == .crypto).
- TransactionLeg.externalId for per-leg (accountId, externalId) dedup
  across re-syncs and cross-device.
- TokenPricingStatus + CryptoRegistration.pricingStatus, defaulting to
  .priced for legacy rows.
- WalletSyncState (per-device, GRDB-local, excluded from CKSyncEngine)
  + WalletSyncError (structured; not a display string) + repository
  protocol added to BackendProvider.
- GRDB migration adding all new columns, indexes, and the
  wallet_sync_state table.
- CloudKit schema additions regenerated via cktool / just generate.
- Defensive AccountType decode in AccountRow — unknown type strings
  fall back to .asset with a logged warning, so older builds receiving
  a "crypto" record from a newer device don't crash.

Per spec: plans/2026-05-05-crypto-wallet-import-design.md.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"

git -C .worktrees/crypto-wallet-foundation push origin feat/crypto-wallet-foundation:feat/crypto-wallet-foundation

gh pr create --title "feat(crypto): foundation — domain types + schema for wallet auto-import" --body "$(cat <<'EOF'
## Summary

Stage 1 of `plans/2026-05-05-crypto-wallet-import-plan.md`. Lands the data-model and schema primitives the rest of the implementation depends on. No behavioural changes for users.

## Test plan

- [ ] `just test` passes on macOS and iOS.
- [ ] `just format-check` passes.
- [ ] Manual: launch existing build, verify no migration errors.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 31: Add PR to merge queue.**

Per memory `feedback_prs_to_merge_queue`, every PR goes through the merge-queue skill:

```bash
~/.claude/skills/merge-queue/scripts/merge-queue-ctl.sh add <PR-NUMBER>
```

Wait for merge. Verify with `gh pr view <PR-NUMBER>` that it landed on `main`.

### Stage 1 acceptance criteria

- [ ] All new domain types defined, tested, format-clean, warning-free.
- [ ] GRDB migration applies cleanly to a fresh DB and to a representative pre-migration DB.
- [ ] CloudKit schema regen committed; generated wire layer matches expected fields.
- [ ] `BackendProvider` exposes `walletSyncState`; production wires `GRDBWalletSyncStateRepository`.
- [ ] All four reviewer agents report no remaining findings.
- [ ] PR merged to main via merge queue.

---

# Stage 2 — Discriminated conversion semantics

**Goal:** Replace `CryptoPriceService.priceUSD(for:on:)`'s plain `Decimal` return with a discriminated `CryptoPriceLookup` (`.priced(Decimal)` / `.knownZero` / throws). Add a parallel `ConversionResult` on `InstrumentConversionService`. Audit every existing site that aggregates legs, and update each to use the discriminated result so a real provider failure marks affected totals unavailable while `.unpriced` / `.spam` tokens contribute zero. **Behaviour unchanged for users** until pricing statuses other than `.priced` exist (Stage 3+).

**Branch:** `feat/crypto-wallet-discriminated-conversion`
**PR title:** `feat(conversion): discriminated price/conversion result for unpriced vs unavailable`

**Files (high-level):**
- Modify: `Shared/CryptoPriceService.swift` — add `priceLookup(...)`; keep `priceUSD(...)` as a thin wrapper for legacy callers (transitional).
- Modify: `Domain/Repositories/InstrumentConversionService.swift` — add `convert(...) -> ConversionResult`.
- Modify: `Shared/InstrumentConversionService` implementation — add `invalidateCache(for:)`.
- Audit + modify: every aggregation path identified by `git grep "legs\." | grep -E "reduce|map.*amount"`. Each site uses the discriminated convert; new error handling logs once per failed instrument per `INSTRUMENT_CONVERSION_GUIDE.md` Rule 11.
- Tests: discriminated conversion + aggregation behavioural tests.

### Tasks

(Detailed bite-sized tasks for Stage 2 will be filled in here once Stage 1 is merged. The shape follows Stage 1: write failing tests; implement; verify; format; reviewer agents; commit; PR; merge queue.)

The substantive tasks list for Stage 2 is enumerated as TODOs in the plan repo issue tracker (filed alongside Stage 1's open issues). Each task is one of:
1. Define `CryptoPriceLookup` enum + tests.
2. Add `priceLookup(...)` to `CryptoPriceService` returning `.knownZero` for `.unpriced`/`.spam` and `.priced(rate)` otherwise.
3. Define `ConversionResult` enum + tests.
4. Add `convert(...) -> ConversionResult` to `InstrumentConversionService`.
5. Add `invalidateCache(for:)` to `InstrumentConversionService`.
6. Run an aggregation-site audit script: `git grep -nE "(legs.*reduce|legs.*map.*amount)" --include='*.swift' > .agent-tmp/leg-aggregation-sites.txt` and walk each site.
7. For each unsafe site: rewrite via discriminated `convert(...)`. Test behaviour for `.priced` (real rate), `.knownZero` (folds in as 0 cleanly), and throwing (marks total unavailable per existing pattern).
8. Reviewer pass: `instrument-conversion-review` + `code-review` + `concurrency-review` (cache-invalidation thread-safety).
9. Format + full test sweep + commit + PR + merge queue.

### Stage 2 acceptance criteria

- [ ] `CryptoPriceLookup` and `ConversionResult` defined, tested.
- [ ] `priceLookup(...)` and discriminated `convert(...)` available; `invalidateCache(for:)` works.
- [ ] Every aggregation-site audit entry marked safe; tests verify the three-way distinction (`.priced` / `.knownZero` / throw) at every aggregation surface.
- [ ] `instrument-conversion-review` agent reports no remaining findings.
- [ ] PR merged via merge queue.

---

# Stage 3 — `pricingStatus` lifecycle

**Goal:** Wire `pricingStatus` into the cross-device merge handler (CKSyncEngine apply-batch), the user-mutation cache-invalidation hook, and the periodic re-resolution path (placeholder hook only — actual periodic logic ships in Stage 9).

**Branch:** `feat/crypto-wallet-pricing-status-lifecycle`
**PR title:** `feat(crypto): pricingStatus cross-device merge + cache invalidation`

**Files (high-level):**
- Modify: GRDB sync apply-batch handler for the instrument-registry record (find via `git grep applyBatchSave | grep -i instrument`).
- Modify: `Features/Settings/CryptoTokenStore.swift` — add `setStatus(_:for:)` that persists + calls `conversionService.invalidateCache(for: instrument)`.
- Tests: cross-device merge for all four cases from the design table; cache-invalidation observable via wallet-total recompute.

### Tasks

(Detailed list filled in after Stage 2 merges.)

### Stage 3 acceptance criteria

- [ ] All four merge-rule cases tested: `.spam` local wins over any incoming; incoming `.spam` accepted; `.priced` beats `.unpriced` either direction.
- [ ] `CryptoTokenStore.setStatus(_:for:)` invalidates the conversion cache synchronously.
- [ ] `sync-review` and `code-review` clean.
- [ ] PR merged via merge queue.

---

# Stage 4 — Wallet data layer

**Goal:** Build the network-facing primitives. `ChainConfig` is a per-chain config table (network slug, native instrument, explorer URL). `AlchemyClient` is a `Sendable struct` mirroring `Backends/CoinGecko/CoinGeckoClient.swift` — `URLSession` + API key, no `APIClient` wrapper. `RateLimiter` is an actor implementing token-bucket throttling. `WalletSyncStateRepository` already exists from Stage 1; this stage is purely additive plumbing.

**Branch:** `feat/crypto-wallet-data-layer`
**PR title:** `feat(crypto): Alchemy client + chain config + rate limiter`

**Files (high-level):**
- Create: `Shared/CryptoImport/ChainConfig.swift`
- Create: `Shared/CryptoImport/AlchemyClient.swift` + protocol
- Create: `Shared/CryptoImport/RateLimiter.swift` (actor)
- Create: `Shared/CryptoImport/AlchemyTransfer.swift` (response decoding type)
- Tests: request shape per chain; response decoding; error mapping; rate-limit behaviour (clock-injected).

### Stage 4 acceptance criteria

- [ ] `AlchemyClient.getAssetTransfers(...)` decodes fixture responses for ETH/OP/Base/Polygon.
- [ ] `RateLimiter` enforces 25 req/s under contention (test with pinned clock).
- [ ] Error mapping: 401 → `.invalidApiKey`, 429 → `.rateLimited(retryAfter:)`, 5xx + network → `.network(...)`.
- [ ] `concurrency-review` and `code-review` clean.
- [ ] PR merged via merge queue.

---

# Stage 5 — Token discovery actor

**Goal:** `CryptoTokenDiscoveryService` actor with the in-flight task coalescer pattern. Concurrent `resolveOrLoad` calls for the same `(chainId, contractAddress)` produce one `CryptoRegistration` and one network round-trip.

**Branch:** `feat/crypto-wallet-token-discovery`
**PR title:** `feat(crypto): token discovery service with in-flight coalescer`

**Files (high-level):**
- Create: `Shared/CryptoImport/CryptoTokenDiscoveryService.swift` (actor)
- Modify: `Shared/CryptoPriceService.swift` — expose a `resolve(...)` path the discovery service can call.
- Tests: concurrent discoveries produce one registration; spam classification; periodic re-resolution rate-gating.

### Stage 5 acceptance criteria

- [ ] In-flight coalescer test passes: 100 concurrent `resolveOrLoad` calls for the same key → 1 network round-trip.
- [ ] `concurrency-review` clean.
- [ ] PR merged via merge queue.

---

# Stage 6 — Build pipeline

**Goal:** `TransferEventBuilder` (raw Alchemy transfers → `BuiltTransaction` with multi-leg structure) and `WalletSyncEngine` (per-account orchestration of the build phase only — no writes).

**Branch:** `feat/crypto-wallet-build-pipeline`
**PR title:** `feat(crypto): wallet sync build pipeline (parallel build phase)`

**Files (high-level):**
- Create: `Shared/CryptoImport/TransferEventBuilder.swift`
- Create: `Shared/CryptoImport/WalletSyncEngine.swift` (Sendable struct)
- Create: `Shared/CryptoImport/BuiltTransaction.swift`
- Tests: single-token send (transfer + gas leg, same externalId); ERC-20 send same; receive-only event has no gas leg; coincident events on same hash group correctly.

### Stage 6 acceptance criteria

- [ ] `WalletSyncEngine.sync(account:)` returns `[BuiltTransaction]` and writes nothing.
- [ ] `concurrency-review` clean.
- [ ] PR merged via merge queue.

---

# Stage 7 — Apply pipeline + transfer-detection extension

**Goal:** `CrossAccountTransferMerger`, the sequential `@MainActor` apply pass, and the eligibility-predicate + same-`externalId` extension to `plans/2026-04-18-transfer-detection-design.md`. The transfer-detection design is *updated* in this PR (the design doc gets a commit) — that doc moves out of "Draft" only when the implementation lands here.

**Branch:** `feat/crypto-wallet-apply-pipeline`
**PR title:** `feat(crypto): cross-account merge + transfer-detection eligibility extension`

**Files (high-level):**
- Create: `Shared/CryptoImport/CrossAccountTransferMerger.swift`
- Modify: existing transfer-detection code (once added) for the eligibility predicate.
- Modify: `plans/2026-04-18-transfer-detection-design.md` — incorporate Extensions A and B from the crypto design.
- Tests: same-hash + opposing legs → single multi-leg transaction; merge runs *only after* parallel build phase; existing two-`.transfer`-leg transfer skipped (already a transfer).

### Stage 7 acceptance criteria

- [ ] Cross-account auto-merge produces correct multi-leg transactions.
- [ ] Transfer-detection design doc updated with both extensions (and the design's "Status: Draft" line updated).
- [ ] Tests verify the algorithm structure (parallel build → sequential apply), not just the outcome.
- [ ] `concurrency-review` and `code-review` clean.
- [ ] PR merged via merge queue.

---

# Stage 8 — Cross-device deduper

**Goal:** `CrossDeviceLegDeduper` post-CKSyncEngine pass. Runs after every `fetchedRecordZoneChanges` callback. Deletes via `TransactionRepository.delete(id:)` (the load-bearing detail). Deterministic UUID-tiebreak.

**Branch:** `feat/crypto-wallet-cross-device-deduper`
**PR title:** `feat(crypto): cross-device leg deduper after CKSyncEngine fetch`

**Files (high-level):**
- Create: `Shared/CryptoImport/CrossDeviceLegDeduper.swift`
- Modify: the CKSyncEngine fetch hook (find via `git grep fetchedRecordZoneChanges`).
- Tests: simulate two-device race → both devices converge on the same canonical leg; orphaned transactions deleted via repository (sync closure verified to fire).

### Stage 8 acceptance criteria

- [ ] Two-device race test passes; both devices end with one `Transaction` row, one leg per account.
- [ ] Test explicitly verifies deletes go through `TransactionRepository.delete(id:)`, not directly to GRDB.
- [ ] `sync-review` clean.
- [ ] PR merged via merge queue.

---

# Stage 9 — Orchestration store

**Goal:** `CryptoSyncStore` (`@MainActor @Observable`) with all triggers — launch, scenePhase, manual refresh, hourly timer with cancellation discipline. Clock-injected for testability. Implements the parallel-build → sequential-apply algorithm using `withTaskGroup`.

**Branch:** `feat/crypto-wallet-sync-store`
**PR title:** `feat(crypto): CryptoSyncStore — triggers + timer + scenePhase`

**Files (high-level):**
- Create: `Features/Crypto/CryptoSyncStore.swift`
- Wire scenePhase observation in the app's root.
- Tests: launch fires sync for stale accounts; foreground re-creates timer after cancellation; `Task.isCancelled` honoured after each sleep; pinned-clock test asserts `WalletSyncState.lastSyncedAt` matches.

### Stage 9 acceptance criteria

- [ ] All four triggers tested.
- [ ] Cancellation discipline tested explicitly (cancel-then-foreground produces fresh timer task).
- [ ] `concurrency-review` clean.
- [ ] PR merged via merge queue.

---

# Stage 10 — UI: account creation

**Goal:** `CryptoAccountCreationView` — name + chain picker + wallet address field. Integrated into the existing account-type picker.

**Branch:** `feat/crypto-wallet-account-creation-ui`
**PR title:** `feat(crypto): account creation UI for wallets`

**Files (high-level):**
- Create: `Features/Crypto/CryptoAccountCreationView.swift`
- Modify: existing account-type picker (find via `git grep "AccountType.investment" Features/`).
- Tests: address validation; chain picker default; account created with correct instrument.
- UI test: full flow happy path.

### Stage 10 acceptance criteria

- [ ] Address validation rejects malformed inputs and accepts valid `0x…` 42-char addresses.
- [ ] Created account has the chain's native instrument set.
- [ ] `ui-review` and `ui-test-review` clean.
- [ ] PR merged via merge queue.

---

# Stage 11 — UI: settings

**Goal:** `CryptoSettingsView` updates (existing file): API key field with status indicator, accounts list with per-account "Sync now" + last-synced, Discovered Tokens inbox, Spam tokens management. Cache invalidation on user-driven status changes (already wired in Stage 3; this is the UI surface).

**Branch:** `feat/crypto-wallet-settings-ui`
**PR title:** `feat(crypto): settings UI — API key, accounts, discovered tokens, spam`

**Files (high-level):**
- Modify: `Features/Settings/CryptoSettingsView.swift`
- Create: `Features/Settings/DiscoveredTokensInboxView.swift`
- Create: `Features/Settings/SpamTokensView.swift`
- Tests: status-change actions invalidate cache; inbox surfaces unpriced tokens; spam list surfaces `.spam` registrations.

### Stage 11 acceptance criteria

- [ ] All three preference surfaces functional and tested.
- [ ] `ui-review` clean.
- [ ] PR merged via merge queue.

---

# Stage 12 — UI: wallet view + transaction detail

**Goal:** `WalletAccountHeaderView` (truncated address, copy button, last-synced, Sync now button), per-leg block-explorer link in transaction detail, `BlockExplorerLink` URL builder per chain.

**Branch:** `feat/crypto-wallet-account-view-ui`
**PR title:** `feat(crypto): wallet account view + transaction detail enhancements`

**Files (high-level):**
- Create: `Features/Crypto/WalletAccountHeaderView.swift`
- Create: `Features/Crypto/BlockExplorerLink.swift`
- Modify: existing transaction-detail view to show explorer link per leg with `externalId`.
- Tests: URL builder for all four chains; header renders correctly; explorer link opens in browser.

### Stage 12 acceptance criteria

- [ ] Explorer URLs correct for ETH/OP/Base/Polygon.
- [ ] `ui-review` clean.
- [ ] PR merged via merge queue.

---

# Stage 13 — Benchmarks

**Goal:** Add `os_signpost` instrumentation at every pipeline stage and the benchmark tests called out in the design.

**Branch:** `feat/crypto-wallet-benchmarks`
**PR title:** `feat(crypto): benchmarks for wallet sync pipeline`

**Files (high-level):**
- Modify: `Shared/CryptoImport/*.swift` — add `os_signpost(.begin/.end)` boundaries.
- Create: `MoolahBenchmarks/CryptoSyncBenchmarks.swift`
- Tests: signpost emission verified by test capture.

### Stage 13 acceptance criteria

- [ ] All four benchmarks listed in the design exist and run.
- [ ] Signpost boundaries cover Alchemy fetch, transfer building, dedup, persistence, rules engine, deduper.
- [ ] PR merged via merge queue.

---

## Self-review (one-shot, prior to handing off)

**Spec coverage:** Every implementation step in the design (steps 1–17) maps to one of stages 1–13 in this plan. Mapping:

| Design step | Plan stage |
|---|---|
| 1 Domain model + audit + migrations | Stage 1 + the audit lives in Stage 2 |
| 2 CryptoPriceService discriminated returns | Stage 2 |
| 3 WalletSyncStateRepository | Stage 1 |
| 4 ChainConfig + AlchemyClient | Stage 4 |
| 5 CryptoTokenDiscoveryService | Stage 5 |
| 6 pricingStatus cross-device merge | Stage 3 |
| 7 TransferEventBuilder | Stage 6 |
| 8 WalletSyncEngine build phase | Stage 6 |
| 9 Transfer-detection extension | Stage 7 |
| 10 CrossAccountTransferMerger | Stage 7 |
| 11 CrossDeviceLegDeduper | Stage 8 |
| 12 CryptoSyncStore | Stage 9 |
| 13 CryptoAccountCreationView | Stage 10 |
| 14 CryptoSettingsView updates | Stage 11 |
| 15 Wallet account view enhancements | Stage 12 |
| 16 Transaction-detail crypto fields | Stage 12 |
| 17 Benchmarks | Stage 13 |

**Placeholder scan:** stages 2–13 are scaffolded outlines, not bite-sized task lists. This is deliberate (the detail depends on as-yet-unwritten code in earlier stages); each stage's bite-sized task list will be added inline before that stage starts. Stage 1 is fully detailed.

**Type consistency:** types defined in Stage 1 (`WalletSyncState`, `WalletSyncError`, `TokenPricingStatus`, `WalletSyncStateRepository`, `Account.walletAddress`, `Account.chainId`, `TransactionLeg.externalId`, `CryptoRegistration.pricingStatus`) are referenced consistently in stages 2–13's prose.

**Open questions filed as issues:** Step 0 of this plan files them all as GitHub issues so any `// TODO(#N)` references resolve.
