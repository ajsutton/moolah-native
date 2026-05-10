# Spam Token Indicator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a transaction leg references an instrument flagged `pricingStatus == .spam`, replace its symbol with an inline `⚠️ Spam` indicator in the row's trade-title sentence, amount column, and balance line — with VoiceOver reading "spam token".

**Architecture:** A derived `Set<Instrument>` on `CryptoTokenStore` (the spam-flagged instruments) is published into the SwiftUI environment via a new `EnvironmentValues.spamInstruments` entry, injected once from `ContentView`. `TransactionRowView` reads the environment and passes the set into (a) a new domain helper `tradeTitleSegments(scopeReference:spamInstruments:)` whose `Text`-rendering wrapper produces the title's parenthesised sentence, (b) a new `SpamAwareAmountView` for the amount column and balance line, and (c) a small accessibility-string helper that substitutes "spam token" for the swapped instrument.

**Tech Stack:** Swift 5.x, SwiftUI 6 (iOS 26 / macOS 26), Swift Testing (`@Test` / `@Suite` / `#expect`), Observation framework (`@Observable`), `swift-format` + SwiftLint via `just format`.

**Spec:** `plans/2026-05-10-spam-transaction-row-indicator-design.md`

**Worktree path used by the example commands:**
```
WORKTREE=/Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/remove-token-provider-badges
```

---

## File Structure

**Create:**
- `Shared/SpamInstrumentsEnvironment.swift` — `EnvironmentValues.spamInstruments` (Set<Instrument>) entry + key, default `[]`.
- `Features/Transactions/Views/SpamAwareAmountView.swift` — view that renders an `InstrumentAmount` either as a normal `InstrumentAmountView` or, when its instrument is in the supplied spam set, as `<magnitude> ⚠️ Spam` in red. Includes a free function `amountAccessibilityString(_:isSpam:)` for VoiceOver substitution.
- `Features/Transactions/Views/TradeTitleSegment+SwiftUI.swift` — SwiftUI-only rendering of `TradeTitleSegment`: the `text: Text` per-segment property and the `Transaction.tradeTitleText(scopeReference:spamInstruments:)` `Text?` wrapper. Lives in `Features/` because the Domain layer must not `import SwiftUI` (CLAUDE.md §Architecture).
- `MoolahTests/Domain/TradeTitleSegmentTests.swift` — replaces `TransactionTradeTitleTests.swift` content to pin segment output of `tradeTitleSegments(...)`, including spam-on-one-side, spam-on-both-sides, and no-spam regression cases.
- `MoolahTests/Features/CryptoTokenStoreSpamInstrumentsTests.swift` — tests for the new derived `spamInstruments` set, using the same in-memory `GRDBInstrumentRegistryRepository` fixture pattern as `CryptoTokenStoreSetStatusTests.swift`.
- `MoolahTests/Shared/AmountAccessibilityStringTests.swift` — tests for the VoiceOver substitution helper.

**Modify:**
- `Features/Settings/CryptoTokenStore.swift` — add derived `spamInstruments: Set<Instrument>` view onto `spamRegistrations`.
- `Domain/Models/InstrumentAmount.swift` — add `formatNoSymbolVariablePrecision` for spam swap rendering.
- `Domain/Models/Transaction+Display.swift` — replace `tradeTitleSentence(scopeReference:)` (`String?`) and `formatLegMagnitude(_:)` with:
  - `enum TradeTitleSegment { case literal(String); case magnitude(InstrumentAmount); case spamMagnitude(InstrumentAmount) }`
  - `func tradeTitleSegments(scopeReference: Instrument, spamInstruments: Set<Instrument>) -> [TradeTitleSegment]?`
  - `var TradeTitleSegment.accessibilityString: String` (Foundation only)
  - The SwiftUI rendering (`tradeTitleText`, `TradeTitleSegment.text`) lives in the new `Features/.../TradeTitleSegment+SwiftUI.swift` file.
- `Features/Transactions/Views/TransactionRowView.swift` — read `@Environment(\.spamInstruments)`, route trade-title rendering through `tradeTitleText`, replace `InstrumentAmountView` calls in `amountColumn` and balance line with `SpamAwareAmountView`, update `accessibilityDescription` to use `amountAccessibilityString` for displayAmounts and balance.
- `App/ContentView.swift` — `.environment(\.spamInstruments, session.cryptoTokenStore?.spamInstruments ?? [])` on the `NavigationSplitView` body.
- `MoolahTests/Domain/TransactionTradeTitleTests.swift` — superseded by `TradeTitleSegmentTests.swift`. Delete the original file.

**Notes:**
- `Instrument` is already `Hashable + Sendable`; `Set<Instrument>` works without further conformance work.
- `CryptoTokenStore` is already `@Observable @MainActor`; reads from any view participate in observation tracking automatically.
- Existing convention for environment-key extensions: `Automation/Navigation/PendingNavigation.swift`.
- **Domain isolation:** `Domain/Models/Transaction+Display.swift` stays Foundation-only. SwiftUI rendering for the segment model lives under `Features/`.

---

## Task 1: Add `CryptoTokenStore.spamInstruments`

**Files:**
- Modify: `Features/Settings/CryptoTokenStore.swift`
- Create: `MoolahTests/Features/CryptoTokenStoreSpamInstrumentsTests.swift`

- [ ] **Step 1: Write the failing test**

The fixture pattern follows `MoolahTests/Features/CryptoTokenStoreSetStatusTests.swift`: in-memory `ProfileDatabase` → `GRDBInstrumentRegistryRepository` → `CryptoTokenStore`, then mark a registration `.spam` via `setStatus(.spam, for:)`. (The registry's `registerCrypto` defaults to `pricingStatus: .priced`; spam is set after the fact.)

Create `$WORKTREE/MoolahTests/Features/CryptoTokenStoreSpamInstrumentsTests.swift`:

```swift
// MoolahTests/Features/CryptoTokenStoreSpamInstrumentsTests.swift
import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("CryptoTokenStore.spamInstruments")
@MainActor
struct CryptoTokenStoreSpamInstrumentsTests {
  private struct Fixture {
    let store: CryptoTokenStore
    let registry: GRDBInstrumentRegistryRepository
  }

  /// Builds a store backed by an in-memory GRDB database, seeded with
  /// the first two built-in presets (BTC, ETH-mainnet) so the test can
  /// flip one to `.spam` and assert membership of `spamInstruments`.
  private func makeStore() async throws -> Fixture {
    let database = try ProfileDatabase.openInMemory()
    let registry = GRDBInstrumentRegistryRepository(database: database)
    for preset in CryptoRegistration.builtInPresets.prefix(2) {
      try await registry.registerCrypto(preset.instrument, mapping: preset.mapping)
    }
    let priceService = CryptoPriceService(
      clients: [FixedCryptoPriceClient()], database: database)
    let conversionService = RecordingConversionService()
    let store = CryptoTokenStore(
      registry: registry,
      cryptoPriceService: priceService,
      conversionService: conversionService)
    await store.loadRegistrations()
    return Fixture(store: store, registry: registry)
  }

  @Test("includes only registrations with .spam status")
  func includesOnlySpam() async throws {
    let fixture = try await makeStore()
    let toMarkSpam = try #require(fixture.store.registrations.first)

    await fixture.store.setStatus(.spam, for: toMarkSpam)

    #expect(fixture.store.spamInstruments == [toMarkSpam.instrument])
  }

  @Test("empty when no registrations are .spam")
  func emptyWhenNoneSpam() async throws {
    let fixture = try await makeStore()
    #expect(fixture.store.spamInstruments.isEmpty)
  }

  @Test("two spam registrations both appear")
  func bothSpamPresent() async throws {
    let fixture = try await makeStore()
    let registrations = fixture.store.registrations
    try #require(registrations.count >= 2)

    await fixture.store.setStatus(.spam, for: registrations[0])
    await fixture.store.setStatus(.spam, for: registrations[1])

    #expect(
      fixture.store.spamInstruments
        == Set([registrations[0].instrument, registrations[1].instrument]))
  }
}
```

(`FixedCryptoPriceClient` and `RecordingConversionService` are existing test doubles already used by `CryptoTokenStoreSetStatusTests.swift`. If their accessibility has narrowed since that test was written, copy the minimal definition needed — both are short.)

- [ ] **Step 2: Run test to verify it fails**

```bash
just test CryptoTokenStoreSpamInstrumentsTests 2>&1 | tee .agent-tmp/test-output.txt
```

Expected: compilation error (`CryptoTokenStore` has no member `spamInstruments`).

- [ ] **Step 3: Add the derived property**

Edit `$WORKTREE/Features/Settings/CryptoTokenStore.swift`. Immediately after the existing `spamRegistrations` computed property (around line 108):

```swift
  /// Set of crypto instruments whose registration is `.spam`. Read by
  /// `TransactionRowView` (via `EnvironmentValues.spamInstruments`) to swap
  /// the leg's instrument symbol for the inline "⚠️ Spam" indicator.
  var spamInstruments: Set<Instrument> {
    Set(spamRegistrations.map(\.instrument))
  }
```

- [ ] **Step 4: Run test to verify it passes**

```bash
just test CryptoTokenStoreSpamInstrumentsTests 2>&1 | tee .agent-tmp/test-output.txt
```

Expected: 2 tests pass.

- [ ] **Step 5: Commit**

```bash
git -C $WORKTREE add Features/Settings/CryptoTokenStore.swift \
  MoolahTests/Features/CryptoTokenStoreSpamInstrumentsTests.swift
git -C $WORKTREE commit -m "feat(crypto): add CryptoTokenStore.spamInstruments derived view"
rm .agent-tmp/test-output.txt
```

---

## Task 2: Add `EnvironmentValues.spamInstruments`

**Files:**
- Create: `Shared/SpamInstrumentsEnvironment.swift`

(No tests — direct EnvironmentValues plumbing has no logic worth pinning. The downstream views verify the wiring end-to-end.)

- [ ] **Step 1: Create the environment key**

Create `$WORKTREE/Shared/SpamInstrumentsEnvironment.swift`:

```swift
import SwiftUI

/// The set of crypto instruments whose `CryptoRegistration.pricingStatus`
/// is currently `.spam` for the active profile. `TransactionRowView` reads
/// this to swap a leg's instrument symbol for an inline "⚠️ Spam" marker
/// in the row's trade-title sentence and amount column.
///
/// The default value is the empty set so previews and tests render without
/// any wiring; only screens that have access to the active `ProfileSession`
/// (currently `ContentView`) inject the live value.
private struct SpamInstrumentsKey: EnvironmentKey {
  static let defaultValue: Set<Instrument> = []
}

extension EnvironmentValues {
  var spamInstruments: Set<Instrument> {
    get { self[SpamInstrumentsKey.self] }
    set { self[SpamInstrumentsKey.self] = newValue }
  }
}
```

- [ ] **Step 2: Verify the file builds**

```bash
just build-mac 2>&1 | tee .agent-tmp/build.txt
```

Expected: `BUILD SUCCEEDED`. If a `project.yml` membership is required for a new file, run `just generate` first; the existing project includes `Shared/**` automatically, so this should not be needed.

- [ ] **Step 3: Commit**

```bash
git -C $WORKTREE add Shared/SpamInstrumentsEnvironment.swift
git -C $WORKTREE commit -m "feat(env): add EnvironmentValues.spamInstruments"
rm .agent-tmp/build.txt
```

---

## Task 3: Trade-title segment model (Domain)

Pure-Foundation segment helpers and tests. The SwiftUI rendering and the caller migration live in Task 4 so the Domain layer stays SwiftUI-free.

**Files:**
- Modify: `Domain/Models/Transaction+Display.swift`
- Modify: `Domain/Models/InstrumentAmount.swift`
- Create: `MoolahTests/Domain/TradeTitleSegmentTests.swift`

- [ ] **Step 1: Write the failing segment tests**

Create `$WORKTREE/MoolahTests/Domain/TradeTitleSegmentTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("Transaction.tradeTitleSegments")
struct TradeTitleSegmentTests {
  let aud = Instrument.AUD
  let usd = Instrument.fiat(code: "USD")
  let gbp = Instrument.fiat(code: "GBP")
  let vgs = Instrument.stock(ticker: "VGS.AX", exchange: "ASX", name: "VGS")
  let eth = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
  let usdc = Instrument.crypto(
    chainId: 1, contractAddress: "0xa0b86", symbol: "USDC", name: "USD Coin", decimals: 6)
  let scam = Instrument.crypto(
    chainId: 1, contractAddress: "0xdeadbeef", symbol: "SCAM",
    name: "Scam Token", decimals: 18)
  let account = UUID()

  private func tradeTxn(
    _ legA: Instrument, _ legAQty: Decimal,
    _ legB: Instrument, _ legBQty: Decimal
  ) -> Transaction {
    Transaction(
      date: Date(),
      legs: [
        TransactionLeg(accountId: account, instrument: legA, quantity: legAQty, type: .trade),
        TransactionLeg(accountId: account, instrument: legB, quantity: legBQty, type: .trade),
      ])
  }

  private func magnitude(_ qty: Decimal, _ instrument: Instrument) -> InstrumentAmount {
    InstrumentAmount(quantity: abs(qty), instrument: instrument)
  }

  // MARK: - Existing semantics (preserved)

  @Test("matching leg negative → Bought")
  func boughtVerb() {
    let txn = tradeTxn(aud, -300, vgs, 20)
    #expect(
      txn.tradeTitleSegments(scopeReference: aud, spamInstruments: []) == [
        .literal("Bought "),
        .magnitude(magnitude(20, vgs)),
      ])
  }

  @Test("matching leg positive → Sold")
  func soldVerb() {
    let txn = tradeTxn(aud, 425, vgs, -10)
    #expect(
      txn.tradeTitleSegments(scopeReference: aud, spamInstruments: []) == [
        .literal("Sold "),
        .magnitude(magnitude(10, vgs)),
      ])
  }

  @Test("non-fiat scope reference matches non-fiat leg → reverse perspective")
  func nonFiatScopeReference() {
    let txn = tradeTxn(aud, -300, vgs, 20)
    #expect(
      txn.tradeTitleSegments(scopeReference: vgs, spamInstruments: []) == [
        .literal("Sold "),
        .magnitude(magnitude(300, aud)),
      ])
  }

  @Test("neither matches → Swapped X for Y")
  func swappedVerb() {
    let txn = tradeTxn(usd, -100, gbp, 50)
    #expect(
      txn.tradeTitleSegments(scopeReference: aud, spamInstruments: []) == [
        .literal("Swapped "),
        .magnitude(magnitude(100, usd)),
        .literal(" for "),
        .magnitude(magnitude(50, gbp)),
      ])
  }

  @Test("non-trade transaction returns nil")
  func nonTradeReturnsNil() {
    let txn = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(accountId: account, instrument: aud, quantity: -50, type: .expense)
      ])
    #expect(txn.tradeTitleSegments(scopeReference: aud, spamInstruments: []) == nil)
  }

  // MARK: - Spam swap

  @Test("Bought {spam} → spam magnitude segment")
  func boughtSpamSwap() {
    let txn = tradeTxn(aud, -300, scam, 1_000_000)
    #expect(
      txn.tradeTitleSegments(scopeReference: aud, spamInstruments: [scam]) == [
        .literal("Bought "),
        .spamMagnitude(magnitude(1_000_000, scam)),
      ])
  }

  @Test("Sold {spam} → spam magnitude segment")
  func soldSpamSwap() {
    let txn = tradeTxn(aud, 300, scam, -1_000_000)
    #expect(
      txn.tradeTitleSegments(scopeReference: aud, spamInstruments: [scam]) == [
        .literal("Sold "),
        .spamMagnitude(magnitude(1_000_000, scam)),
      ])
  }

  @Test("Swapped: only spam side is swapped")
  func swappedOneSidedSpamSwap() {
    let txn = tradeTxn(eth, -1, scam, 50_000)
    #expect(
      txn.tradeTitleSegments(scopeReference: aud, spamInstruments: [scam]) == [
        .literal("Swapped "),
        .magnitude(magnitude(1, eth)),
        .literal(" for "),
        .spamMagnitude(magnitude(50_000, scam)),
      ])
  }

  @Test("Swapped: both sides spam → both swapped")
  func swappedBothSpamSwap() {
    let txn = tradeTxn(usdc, -100, scam, 50_000)
    #expect(
      txn.tradeTitleSegments(scopeReference: aud, spamInstruments: [usdc, scam]) == [
        .literal("Swapped "),
        .spamMagnitude(magnitude(100, usdc)),
        .literal(" for "),
        .spamMagnitude(magnitude(50_000, scam)),
      ])
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
just test TradeTitleSegmentTests 2>&1 | tee .agent-tmp/test-output.txt
```

Expected: compilation error (`tradeTitleSegments` and `TradeTitleSegment` don't exist).

- [ ] **Step 3: Add the variable-precision magnitude formatter on `InstrumentAmount`**

Edit `$WORKTREE/Domain/Models/InstrumentAmount.swift` and add this property next to the existing `formatNoSymbol` (around line 33):

```swift
  /// Quantity-only formatting matching the variable-precision rule used
  /// by `formatted` for stocks and crypto (no trailing zeros). Used by
  /// the spam-token row indicator where the symbol is replaced by a
  /// SwiftUI `Text` segment instead of being concatenated into the
  /// number string.
  var formatNoSymbolVariablePrecision: String {
    quantity.formatted(.number.precision(.fractionLength(0...instrument.decimals)))
  }
```

- [ ] **Step 4: Implement `TradeTitleSegment` + `tradeTitleSegments` in the Domain layer**

Replace the entire `// MARK: - Trade Title` extension at the bottom of `$WORKTREE/Domain/Models/Transaction+Display.swift` with:

```swift
// MARK: - Trade Title

/// Building block for the row's parenthesised action sentence on a `.trade`
/// transaction. `magnitude` and `spamMagnitude` carry the same numeric
/// value; the view layer renders `.magnitude` as the instrument's normal
/// formatted string and `.spamMagnitude` as `<numericMagnitude> ⚠️ Spam`
/// in red.
enum TradeTitleSegment: Equatable, Sendable {
  case literal(String)
  case magnitude(InstrumentAmount)
  case spamMagnitude(InstrumentAmount)
}

extension TradeTitleSegment {
  /// VoiceOver substitution. Spam magnitudes read as
  /// "<magnitude> spam token" (lowercase, spelled out) so the warning
  /// glyph is never announced as punctuation.
  var accessibilityString: String {
    switch self {
    case .literal(let s): return s
    case .magnitude(let amount): return amount.formatted
    case .spamMagnitude(let amount):
      return "\(amount.formatNoSymbolVariablePrecision) spam token"
    }
  }
}

extension Transaction {
  /// Builds the action sentence segments for a `.trade` row title. Returns
  /// `nil` for non-trade transactions or trades that don't have exactly two
  /// `.trade` legs (matching the prior `tradeTitleSentence` contract).
  ///
  /// `scopeReference` is the row's reference instrument: the account's
  /// instrument when account-scoped, the earmark's instrument when
  /// earmark-scoped, otherwise the profile currency. `spamInstruments`
  /// is the set of instruments currently flagged `pricingStatus == .spam`;
  /// any leg whose instrument falls in that set is emitted as
  /// `.spamMagnitude(...)` so the renderer can swap it for the spam marker.
  func tradeTitleSegments(
    scopeReference: Instrument,
    spamInstruments: Set<Instrument>
  ) -> [TradeTitleSegment]? {
    guard isTrade else { return nil }
    let tradeLegs = legs.filter { $0.type == .trade }
    guard tradeLegs.count == 2 else { return nil }
    let (legA, legB) = (tradeLegs[0], tradeLegs[1])

    let aMatches = legA.instrument == scopeReference
    let bMatches = legB.instrument == scopeReference
    if aMatches != bMatches {
      let matching = aMatches ? legA : legB
      let other = aMatches ? legB : legA
      let verb = matching.quantity < 0 ? "Bought" : "Sold"
      return [
        .literal("\(verb) "),
        magnitudeSegment(for: other, spamInstruments: spamInstruments),
      ]
    }
    let paid = legA.quantity < 0 ? legA : legB
    let received = legA.quantity < 0 ? legB : legA
    return [
      .literal("Swapped "),
      magnitudeSegment(for: paid, spamInstruments: spamInstruments),
      .literal(" for "),
      magnitudeSegment(for: received, spamInstruments: spamInstruments),
    ]
  }

  private func magnitudeSegment(
    for leg: TransactionLeg,
    spamInstruments: Set<Instrument>
  ) -> TradeTitleSegment {
    let amount = InstrumentAmount(
      quantity: abs(leg.quantity), instrument: leg.instrument)
    if spamInstruments.contains(leg.instrument) {
      return .spamMagnitude(amount)
    }
    return .magnitude(amount)
  }
}
```

This deletes the prior `tradeTitleSentence(scopeReference:) -> String?` and `formatLegMagnitude(_:)` functions on `Transaction`. The single in-tree caller (`TransactionRowView.titleText`) breaks at this point — Task 4 fixes it. **Don't run `just build-mac` until Task 4's caller migration is in place.**

- [ ] **Step 5: Run segment tests to verify they pass**

The Domain layer compiles and `MoolahTests` builds against the symbol — the broken caller is in the main-app target, but the test target should still find `tradeTitleSegments`:

```bash
just test TradeTitleSegmentTests 2>&1 | tee .agent-tmp/test-output.txt
```

If the build of the main app target trips before the test runs, that's expected and gets resolved by Task 4. If you can't get the test framework to bypass the broken `TransactionRowView.titleText`, proceed to Task 4 first and re-run after.

Otherwise expected: 9 segment tests pass.

- [ ] **Step 6: Do not commit yet**

The Domain change leaves `TransactionRowView` referencing a deleted function. Task 4 finishes the caller migration in the same commit so `main` is never broken. Move on to Task 4.

---

## Task 4: SwiftUI rendering for `TradeTitleSegment` + caller migration

The Domain layer is SwiftUI-free, so the `Text`-returning rendering for `TradeTitleSegment` lives under `Features/`. This task adds that file, migrates `TransactionRowView`'s title to use it, and commits Tasks 3 + 4 together so the build stays green.

**Files:**
- Create: `Features/Transactions/Views/TradeTitleSegment+SwiftUI.swift`
- Modify: `Features/Transactions/Views/TransactionRowView.swift`
- Delete: `MoolahTests/Domain/TransactionTradeTitleTests.swift`

- [ ] **Step 1: Add the SwiftUI rendering file**

Create `$WORKTREE/Features/Transactions/Views/TradeTitleSegment+SwiftUI.swift`:

```swift
import SwiftUI

extension TradeTitleSegment {
  /// SwiftUI rendering of a single segment. `.literal` and `.magnitude`
  /// pass through unstyled; `.spamMagnitude` emits the formatted quantity
  /// followed by the warning glyph and the word "Spam", both in red.
  var text: Text {
    switch self {
    case .literal(let s):
      return Text(s)
    case .magnitude(let amount):
      return Text(amount.formatted)
    case .spamMagnitude(let amount):
      return Text("\(amount.formatNoSymbolVariablePrecision) ")
        + Text(Image(systemName: "exclamationmark.triangle.fill"))
          .foregroundStyle(.red)
        + Text("Spam").foregroundStyle(.red)
    }
  }
}

extension Transaction {
  /// SwiftUI `Text` rendering of `tradeTitleSegments`, ready to drop into
  /// the row title. `nil` for non-trade transactions.
  func tradeTitleText(
    scopeReference: Instrument,
    spamInstruments: Set<Instrument>
  ) -> Text? {
    guard let segments = tradeTitleSegments(
      scopeReference: scopeReference, spamInstruments: spamInstruments)
    else { return nil }
    return segments.reduce(Text("")) { partial, segment in
      partial + segment.text
    }
  }
}
```

- [ ] **Step 2: Migrate `TransactionRowView.titleText` to the new renderer**

Edit `$WORKTREE/Features/Transactions/Views/TransactionRowView.swift`. Replace the existing `private var titleText: String { ... }` (around line 158) and the `Text(titleText).lineLimit(1)` line in `infoColumn` (around line 39) with:

```swift
  private var infoColumn: some View {
    VStack(alignment: .leading, spacing: 2) {
      titleView
      metadataRow
    }
  }

  private var titleView: some View {
    titleTextValue.lineLimit(1)
  }

  /// Composed title for the row. For trade transactions, builds a `Text`
  /// concatenation that may include inline spam markers (red glyph + "Spam"
  /// substituted for the spam-flagged leg's instrument symbol). For other
  /// transactions, returns the plain payee.
  private var titleTextValue: Text {
    let payee = displayPayee
    if let sentence = transaction.tradeTitleText(
      scopeReference: scopeReferenceInstrument,
      spamInstruments: []  // Task 6 wires this to @Environment(\.spamInstruments)
    ) {
      if payee.isEmpty {
        return sentence
      }
      return Text("\(payee) (") + sentence + Text(")")
    }
    return Text(payee)
  }

  /// Plain-string equivalent of the title used by `accessibilityDescription`.
  /// Reuses `tradeTitleSegments` and joins via `accessibilityString` so spam
  /// magnitudes read as "<magnitude> spam token" instead of triggering the
  /// glyph-as-punctuation announcement that `tradeTitleText` would emit.
  private var titleAccessibilityString: String {
    let payee = displayPayee
    guard let segments = transaction.tradeTitleSegments(
      scopeReference: scopeReferenceInstrument, spamInstruments: [])
    else { return payee }
    let sentence = segments.map(\.accessibilityString).joined()
    return payee.isEmpty ? sentence : "\(payee) (\(sentence))"
  }
```

In `accessibilityDescription` (around line 86), replace the two occurrences of `\(titleText)` with `\(titleAccessibilityString)`.

- [ ] **Step 3: Delete the legacy test file**

```bash
git -C $WORKTREE rm MoolahTests/Domain/TransactionTradeTitleTests.swift
```

- [ ] **Step 4: Build, format, and run tests**

```bash
just format 2>&1 | tee .agent-tmp/format.txt
just build-mac 2>&1 | tee .agent-tmp/build.txt
just test TradeTitleSegmentTests 2>&1 | tee .agent-tmp/test-output.txt
```

Expected: clean format, BUILD SUCCEEDED, 9 segment tests pass.

- [ ] **Step 5: Run the full suite**

```bash
just test 2>&1 | tee .agent-tmp/test-output.txt
grep -i 'failed\|error:' .agent-tmp/test-output.txt | head
```

Expected: zero failures introduced. (`spamInstruments: []` produces segment output equivalent to the prior flat-string form for non-spam cases, so existing row behaviour is unchanged.)

- [ ] **Step 6: Commit Tasks 3 + 4 together**

```bash
git -C $WORKTREE add Domain/Models/Transaction+Display.swift \
  Domain/Models/InstrumentAmount.swift \
  Features/Transactions/Views/TradeTitleSegment+SwiftUI.swift \
  Features/Transactions/Views/TransactionRowView.swift \
  MoolahTests/Domain/TradeTitleSegmentTests.swift
git -C $WORKTREE commit -m "refactor(transactions): replace tradeTitleSentence with segment model + Text renderer"
rm .agent-tmp/test-output.txt .agent-tmp/build.txt .agent-tmp/format.txt
```

(`MoolahTests/Domain/TransactionTradeTitleTests.swift` is staged for deletion automatically by the prior `git rm`.)

---

## Task 5: Build `SpamAwareAmountView` + accessibility helper

**Files:**
- Create: `Features/Transactions/Views/SpamAwareAmountView.swift`
- Create: `MoolahTests/Shared/AmountAccessibilityStringTests.swift`

- [ ] **Step 1: Write the failing accessibility-helper tests**

Create `$WORKTREE/MoolahTests/Shared/AmountAccessibilityStringTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("amountAccessibilityString")
struct AmountAccessibilityStringTests {
  let aud = Instrument.AUD
  let scam = Instrument.crypto(
    chainId: 1, contractAddress: "0xdeadbeef", symbol: "SCAM",
    name: "Scam Token", decimals: 18)

  @Test("non-spam falls through to .formatted")
  func nonSpamPassesThrough() {
    let amount = InstrumentAmount(quantity: -50.23, instrument: aud)
    #expect(amountAccessibilityString(amount, isSpam: false) == amount.formatted)
  }

  @Test("spam reads as <magnitude> spam token")
  func spamSubstitutes() {
    let amount = InstrumentAmount(quantity: 1_000_000, instrument: scam)
    #expect(
      amountAccessibilityString(amount, isSpam: true)
        == "\(amount.formatNoSymbolVariablePrecision) spam token")
  }

  @Test("spam preserves negative magnitude in VoiceOver string")
  func spamNegativeMagnitudePreserved() {
    let amount = InstrumentAmount(quantity: -50, instrument: scam)
    let result = amountAccessibilityString(amount, isSpam: true)
    #expect(result.contains("-50"))
    #expect(result.hasSuffix("spam token"))
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
just test AmountAccessibilityStringTests 2>&1 | tee .agent-tmp/test-output.txt
```

Expected: compilation error (`amountAccessibilityString` not defined).

- [ ] **Step 3: Implement `SpamAwareAmountView` + `amountAccessibilityString`**

Create `$WORKTREE/Features/Transactions/Views/SpamAwareAmountView.swift`:

```swift
import SwiftUI

/// Renders an `InstrumentAmount` exactly as `InstrumentAmountView` does
/// when the instrument is not in `spamInstruments`. When it is, replaces
/// the symbol portion with the inline "⚠️ Spam" indicator (red) and emits
/// a substituted VoiceOver string ("<magnitude> spam token"). The
/// magnitude's sign is preserved.
struct SpamAwareAmountView: View {
  let amount: InstrumentAmount
  let spamInstruments: Set<Instrument>
  var font: Font?
  var colorOverride: Color?

  var body: some View {
    if spamInstruments.contains(amount.instrument) {
      spamBody
        .accessibilityLabel(Text("Amount"))
        .accessibilityValue(amountAccessibilityString(amount, isSpam: true))
    } else {
      InstrumentAmountView(amount: amount, font: font, colorOverride: colorOverride)
    }
  }

  private var spamBody: some View {
    (Text("\(amount.formatNoSymbolVariablePrecision) ")
      .foregroundStyle(colorOverride ?? defaultMagnitudeColor)
      + Text(Image(systemName: "exclamationmark.triangle.fill"))
        .foregroundStyle(.red)
      + Text(" Spam").foregroundStyle(.red))
      .monospacedDigit()
      .font(font)
  }

  private var defaultMagnitudeColor: Color {
    if amount.isPositive { return .green }
    if amount.isNegative { return .red }
    return .primary
  }
}

/// VoiceOver substitution for spam-flagged amounts. Used by both
/// `SpamAwareAmountView`'s accessibility value and `TransactionRowView`'s
/// composed `accessibilityDescription` so the warning glyph is never
/// announced as punctuation.
func amountAccessibilityString(
  _ amount: InstrumentAmount, isSpam: Bool
) -> String {
  if isSpam {
    return "\(amount.formatNoSymbolVariablePrecision) spam token"
  }
  return amount.formatted
}
```

- [ ] **Step 4: Run accessibility tests to verify they pass**

```bash
just test AmountAccessibilityStringTests 2>&1 | tee .agent-tmp/test-output.txt
```

Expected: 3 tests pass.

- [ ] **Step 5: Build to confirm view compiles**

```bash
just build-mac 2>&1 | tee .agent-tmp/build.txt
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git -C $WORKTREE add Features/Transactions/Views/SpamAwareAmountView.swift \
  MoolahTests/Shared/AmountAccessibilityStringTests.swift
git -C $WORKTREE commit -m "feat(transactions): SpamAwareAmountView + amountAccessibilityString helper"
rm .agent-tmp/test-output.txt .agent-tmp/build.txt
```

---

## Task 6: Wire `TransactionRowView` to the spam environment

**Files:**
- Modify: `Features/Transactions/Views/TransactionRowView.swift`

- [ ] **Step 1: Add the environment read**

Add immediately under the existing `@ScaledMetric` block in `TransactionRowView` (around line 21):

```swift
  @Environment(\.spamInstruments) private var spamInstruments
```

- [ ] **Step 2: Pass `spamInstruments` into the title renderer**

Edit `titleTextValue` (added in Task 4) so it forwards the environment value instead of `[]`:

```swift
  private var titleTextValue: Text {
    let payee = displayPayee
    if let sentence = transaction.tradeTitleText(
      scopeReference: scopeReferenceInstrument,
      spamInstruments: spamInstruments
    ) {
      if payee.isEmpty {
        return sentence
      }
      return Text("\(payee) (") + sentence + Text(")")
    }
    return Text(payee)
  }
```

And `titleAccessibilityString` likewise:

```swift
  private var titleAccessibilityString: String {
    let payee = displayPayee
    guard let segments = transaction.tradeTitleSegments(
      scopeReference: scopeReferenceInstrument, spamInstruments: spamInstruments)
    else { return payee }
    let sentence = segments.map(\.accessibilityString).joined()
    return payee.isEmpty ? sentence : "\(payee) (\(sentence))"
  }
```

- [ ] **Step 3: Replace `InstrumentAmountView` calls with `SpamAwareAmountView`**

The current row passes `font: .caption` to the balance-line `InstrumentAmountView` and no `colorOverride`. Match that exactly — adding a `colorOverride` here would change the balance's colour semantics (positive=green / negative=red) into a uniform secondary tint, which is a separate visual decision.

Replace `amountColumn` (around line 69) with:

```swift
  private var amountColumn: some View {
    VStack(alignment: .trailing, spacing: 2) {
      if displayAmounts.isEmpty {
        Text("—")
          .font(.body)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      } else {
        TradeAmountFlow(amounts: displayAmounts, spamInstruments: spamInstruments)
      }
      if let balance {
        SpamAwareAmountView(
          amount: balance,
          spamInstruments: spamInstruments,
          font: .caption)
      }
    }
  }
```

Update `TradeAmountFlow` (the private inline-wrap layout struct further down the file) to accept and pass through the spam set:

```swift
private struct TradeAmountFlow: View {
  let amounts: [InstrumentAmount]
  let spamInstruments: Set<Instrument>
  var body: some View {
    WrappedHStack(spacing: 6) {
      ForEach(amounts, id: \.self) { amount in
        SpamAwareAmountView(
          amount: amount, spamInstruments: spamInstruments, font: .body)
      }
    }
    .multilineTextAlignment(.trailing)
  }
}
```

- [ ] **Step 4: Update `accessibilityDescription` to substitute spam amounts**

Replace the `displayAmounts.map(\.formatted).joined(...)` line with a substitution-aware variant. In `accessibilityDescription` (around line 86):

```swift
    let amountStr =
      displayAmounts.isEmpty
      ? "amount unavailable"
      : displayAmounts
        .map { amountAccessibilityString($0, isSpam: spamInstruments.contains($0.instrument)) }
        .joined(separator: " and ")
```

And replace `balance \(balance.formatted)` with `balance \(amountAccessibilityString(balance, isSpam: spamInstruments.contains(balance.instrument)))`. Final snippet:

```swift
    if let balance {
      return
        "\(typeStr), \(titleAccessibilityString), \(amountStr), \(dateStr), balance \(amountAccessibilityString(balance, isSpam: spamInstruments.contains(balance.instrument)))"
    } else {
      return "\(typeStr), \(titleAccessibilityString), \(amountStr), \(dateStr)"
    }
```

- [ ] **Step 5: Format + build**

```bash
just format 2>&1 | tee .agent-tmp/format.txt
just build-mac 2>&1 | tee .agent-tmp/build.txt
```

Expected: format clean, BUILD SUCCEEDED, no new warnings (project has `SWIFT_TREAT_WARNINGS_AS_ERRORS: YES`).

- [ ] **Step 6: Run the full suite**

```bash
just test 2>&1 | tee .agent-tmp/test-output.txt
grep -i 'failed\|error:' .agent-tmp/test-output.txt | head
```

Expected: no failures introduced.

- [ ] **Step 7: Commit**

```bash
git -C $WORKTREE add Features/Transactions/Views/TransactionRowView.swift
git -C $WORKTREE commit -m "feat(transactions): TransactionRowView reads spamInstruments from environment"
rm .agent-tmp/test-output.txt .agent-tmp/build.txt .agent-tmp/format.txt
```

---

## Task 7: Inject `\.spamInstruments` from `ContentView`

**Files:**
- Modify: `App/ContentView.swift`

- [ ] **Step 1: Inject the environment value**

In `$WORKTREE/App/ContentView.swift`, edit the `body` property's `NavigationSplitView` modifier chain. Add the environment injection just after `.navigationSplitViewStyle(.balanced)` (around line 74):

```swift
    .navigationSplitViewStyle(.balanced)
    .environment(\.spamInstruments, session.cryptoTokenStore?.spamInstruments ?? [])
```

The `session.cryptoTokenStore` is `@Observable`, so reading `spamInstruments` here makes `ContentView` re-evaluate its body whenever a registration's status flips — which in turn re-injects the environment and re-renders every descendant `TransactionRowView`.

- [ ] **Step 2: Build + run a smoke test**

```bash
just format 2>&1 | tee .agent-tmp/format.txt
just build-mac 2>&1 | tee .agent-tmp/build.txt
just test TransactionStoreCRUDTests 2>&1 | tee .agent-tmp/test-output.txt
```

Expected: clean format, BUILD SUCCEEDED, transactions store tests pass (covers the most common code path that loads transactions into the row).

- [ ] **Step 3: Commit**

```bash
git -C $WORKTREE add App/ContentView.swift
git -C $WORKTREE commit -m "feat(app): inject spamInstruments environment from ContentView"
rm .agent-tmp/test-output.txt .agent-tmp/build.txt .agent-tmp/format.txt
```

---

## Task 8: Add a spam-row preview variant

**Files:**
- Modify: `Features/Transactions/Views/TransactionRowView.swift` (or `TransactionRowView+Preview.swift` if the preview block has been split off — check first)

- [ ] **Step 1: Locate the preview block**

```bash
grep -n "previewRowSpecs\|#Preview" $WORKTREE/Features/Transactions/Views/TransactionRowView*.swift
```

If a sibling `TransactionRowView+Preview.swift` exists, edit that. Otherwise edit the `#Preview` and supporting helpers at the bottom of `TransactionRowView.swift`.

- [ ] **Step 2: Add a spam-flagged crypto instrument + spec**

Inside `TransactionRowPreviewData`, add:

```swift
  let scam = Instrument.crypto(
    chainId: 1, contractAddress: "0xdeadbeef", symbol: "SCAM",
    name: "Scam Token", decimals: 18)
```

Append a new spec to `tradePreviewSpecs(data:)`:

```swift
    PreviewRowSpec(
      payee: "Suspicious Wallet",
      legs: [
        TransactionLeg(
          accountId: data.sourceId, instrument: .AUD, quantity: -100, type: .trade),
        TransactionLeg(
          accountId: data.savingsId, instrument: data.scam, quantity: 1_000_000, type: .trade),
      ],
      displayAmounts: [
        InstrumentAmount(quantity: -100, instrument: .AUD),
        InstrumentAmount(quantity: 1_000_000, instrument: data.scam),
      ],
      balance: -1_549.77, viewingAccountId: data.sourceId)
```

Wrap the existing `#Preview { ... }` block so the preview itself injects the spam set:

```swift
#Preview {
  let data = TransactionRowPreviewData()
  return List {
    ForEach(Array(previewRowSpecs(data: data).enumerated()), id: \.offset) { _, spec in
      previewRow(
        data: data, payee: spec.payee, legs: spec.legs,
        displayAmounts: spec.displayAmounts, balance: spec.balance,
        viewingAccountId: spec.viewingAccountId)
    }
  }
  .environment(\.spamInstruments, [data.scam])
}
```

- [ ] **Step 3: Render the preview to confirm visuals**

Use `mcp__xcode__RenderPreview` (or open the canvas in Xcode) on `TransactionRowView`. Confirm:
- Trade row shows `Suspicious Wallet (Swapped $100.00 for 1,000,000 ⚠️ Spam)` — only the spam side is swapped, fiat side unchanged.
- Amount column for the spam leg reads `1,000,000 ⚠️ Spam` in red.
- Other rows are unchanged.

If anything looks off, iterate on `SpamAwareAmountView` / segment renderer until the preview matches the spec's example screenshots in `plans/2026-05-10-spam-transaction-row-indicator-design.md`.

- [ ] **Step 4: Format + commit**

```bash
just format 2>&1 | tee .agent-tmp/format.txt
git -C $WORKTREE add Features/Transactions/Views/TransactionRowView.swift \
  Features/Transactions/Views/TransactionRowView+Preview.swift 2>/dev/null || true
git -C $WORKTREE commit -m "test(transactions): preview row variant for spam-token swap"
rm .agent-tmp/format.txt
```

(`||` `true` is in case the +Preview.swift split doesn't exist; only one path will need staging.)

---

## Task 9: UI test — spam row shows the indicator

**Files:**
- Modify: `MoolahUITests_macOS/...` (existing test file related to transaction lists)
- Modify: `UITestSupport/UITestSeeds.swift` if a new seed primitive is required

This task is **optional**: if writing it requires more than ~30 minutes of seed scaffolding, skip it. Document the skip in the commit message of Task 8 (e.g. "Note: deferring UI test to a follow-up — see plans/…-design.md test plan."). The unit-level coverage from Tasks 1, 3, and 5 is the floor.

- [ ] **Step 1: Decide whether to proceed**

```bash
ls $WORKTREE/MoolahUITests_macOS/
ls $WORKTREE/UITestSupport/
```

Locate an existing test that drives `TransactionListView` (e.g. `TransactionsScreenTests.swift` or similar). If no seed primitive currently creates a spam-marked registration, check the seed list in `UITestSeeds.swift` — adding one is a few lines if `TestBackend` already supports `pricingStatus: .spam` upserts (it does, per Task 1).

Follow `superpowers:writing-ui-tests` from this point. If the cost looks higher than the value for a label-only feature, stop and skip per the optional note above.

- [ ] **Step 2: Add the test**

Following `guides/UI_TEST_GUIDE.md` (screen-driver rule, identifier discipline, no sleeps), add a test that:
- Seeds: one priced AUD account, one spam registration (`scam`), one transaction with two legs (AUD outgoing, SCAM incoming).
- Asserts: the row identified by `UITestIdentifiers.TransactionList.transaction(id)` exposes an accessibility value containing `"spam token"`.

Use only XCTest at the test level; the screen driver lives under `MoolahUITests_macOS/Drivers/` (or equivalent).

- [ ] **Step 3: Run the UI test**

```bash
just test SpamRowIndicatorUITests 2>&1 | tee .agent-tmp/test-output.txt
```

Adjust the suite name to whatever you named the file. Expected: passes on macOS.

- [ ] **Step 4: Commit**

```bash
git -C $WORKTREE add MoolahUITests_macOS/ UITestSupport/
git -C $WORKTREE commit -m "test(ui): assert spam row exposes 'spam token' to accessibility"
rm .agent-tmp/test-output.txt
```

---

## Final verification

- [ ] **Step 1: Format check**

```bash
just format-check 2>&1 | tee .agent-tmp/format-check.txt
```

Expected: clean. If any diff appears, run `just format` and re-commit (do NOT modify `.swiftlint-baseline.yml`; if a SwiftLint baseline entry trips, fix the underlying code).

- [ ] **Step 2: Full test suite**

```bash
just test 2>&1 | tee .agent-tmp/test-final.txt
grep -i 'failed\|error:' .agent-tmp/test-final.txt | head
```

Expected: zero failures.

- [ ] **Step 3: Compiler-warning sweep**

In Xcode (or via `mcp__xcode__XcodeListNavigatorIssues` with `severity: "warning"`) confirm zero warnings in user code. The project sets `SWIFT_TREAT_WARNINGS_AS_ERRORS: YES`, so any warning would have already failed step 1's build — this is belt-and-braces.

- [ ] **Step 4: Cleanup**

```bash
rm -f .agent-tmp/*.txt
```

- [ ] **Step 5: Optional review-agent pass**

Per CLAUDE.md, run `code-review` and `ui-review` on the staged commits before opening the PR:

```bash
# In Claude Code:
@code-review please review the diff on this branch against guides/CODE_GUIDE.md
@ui-review please review the spam row treatment against guides/UI_GUIDE.md
```

Address any Critical/Important findings; ask before deferring Minor ones.

---

## Self-review checklist

- **Spec coverage:** Every section of the spec maps to a task. Detection (T1), environment plumbing (T2 + T7), domain segment model (T3), title rendering (T4), amount column + balance + accessibility (T5 + T6), preview verification (T8), UI test (T9 optional). ✅
- **Placeholders:** None. Every step has an exact path and inline code.
- **Type consistency:** `tradeTitleSegments` returns `[TradeTitleSegment]?` everywhere it appears; `tradeTitleText` returns `Text?`; `SpamAwareAmountView`'s parameters (`amount: InstrumentAmount`, `spamInstruments: Set<Instrument>`, `font: Font?`, `colorOverride: Color?`) match in T5 and the call sites in T6; `amountAccessibilityString(_:isSpam:)` is the only accessibility helper at module scope and is used in T5 (tests + view body), T6 (×3 in row's `accessibilityDescription`), and as a sibling pattern via `TradeTitleSegment.accessibilityString` in T3.
- **Domain isolation:** No `import SwiftUI` in any `Domain/` change. SwiftUI rendering of `TradeTitleSegment` lives in `Features/Transactions/Views/TradeTitleSegment+SwiftUI.swift` (T4).
- **Frequent commits:** Tasks 3 and 4 share a single commit (the Domain change leaves a dangling caller until T4 fixes it); every other task ends in its own commit. Commit messages follow the repo's `feat(scope):` / `refactor(scope):` / `test(scope):` convention.
- **TDD:** Tasks 1, 3, 5 are red-green-refactor. Tasks 2, 4, 6, 7, 8 are plumbing / glue / preview where the testable logic is already covered upstream; their correctness is verified by the existing suites and the preview render in T8.
