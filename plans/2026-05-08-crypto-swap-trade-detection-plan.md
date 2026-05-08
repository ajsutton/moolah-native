# Crypto Swap → `.trade` Leg Detection — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When importing a crypto wallet, retype per-account legs from `.income` / `.expense` to `.trade` whenever a single on-chain hash represents a token swap on this account (≥1 inbound + ≥1 outbound non-fee leg, ≥2 distinct instruments). Gas leg stays `.expense`. Forward-only — no backfill of existing rows.

**Architecture:** A new pure helper `IntraAccountSwapDetector` sits inside `Shared/CryptoImport/` and is called from `TransferEventBuilder.buildEvent` after per-event leg construction and before the gas leg is appended. The builder's private `makeTransferLeg` is changed to return a `DirectionalLeg` (leg + direction) so the detector can distinguish self-sends from real inbounds without inferring from `counterpartyAddress`. `Transaction.isTrade` and `TradeEventClassifier` are not modified — the canonical 2-leg case lights them up automatically; 3+ leg swaps stay `.trade`-typed but don't auto-classify into FIFO events.

**Tech Stack:** Swift, Swift Testing (`@Suite`/`@Test`/`#expect`/`#require`), `just` build/format/test targets, Swift Concurrency.

---

## Spec

Full spec: `plans/2026-05-08-crypto-swap-trade-detection-design.md`. Read it before starting Task 1 — every task references shapes from there.

## File Structure

- New: `Shared/CryptoImport/IntraAccountSwapDetector.swift`
  - `struct DirectionalLeg: Sendable` (top-level, internal, holds `leg: TransactionLeg` + `direction: TransferDirection`).
  - `enum IntraAccountSwapDetector` with a single `static func retypeSwapLegs(_:)` method.
- New: `MoolahTests/Shared/CryptoImport/IntraAccountSwapDetectorTests.swift`
  - Pure unit tests over `[DirectionalLeg] → [TransactionLeg]`. No async.
- New: `MoolahTests/Shared/CryptoImport/TransferEventBuilderSwapTests.swift`
  - Integration tests against `TransferEventBuilder.build(...)` exercising swap shapes.
- Modified: `Shared/CryptoImport/TransferEventBuilder.swift`
  - `private func makeTransferLeg(...)` returns `DirectionalLeg?` instead of `TransactionLeg?`.
  - `buildEvent(...)` collects `[DirectionalLeg]`, calls the detector, then appends the gas leg.
- Possibly modified: `Shared/CryptoImport/TransferEventBuilder+NativeRegistration.swift`
  - `legType(for:)` may stay or move; default is to leave as-is.
- Modified: `MoolahTests/Shared/CryptoImport/CrossAccountTransferMergerTests.swift`
  - One added `@Test` proving a swap candidate (legs all `.trade`) passes through untouched.

Existing builder test files **may need** small fixture audits if any of them produce a swap shape (1 in + 1 out across distinct instruments on one hash for one account); check during Task 7.

---

## Task 1: Detector skeleton + first failing 2-token swap test

**Files:**
- Create: `Shared/CryptoImport/IntraAccountSwapDetector.swift`
- Create: `MoolahTests/Shared/CryptoImport/IntraAccountSwapDetectorTests.swift`

- [ ] **Step 1: Write the failing test**

Create `MoolahTests/Shared/CryptoImport/IntraAccountSwapDetectorTests.swift`:

```swift
// MoolahTests/Shared/CryptoImport/IntraAccountSwapDetectorTests.swift
import Foundation
import Testing

@testable import Moolah

/// Pure unit tests for `IntraAccountSwapDetector`. The detector is a
/// total `[DirectionalLeg] → [TransactionLeg]` function with no async,
/// no fixtures beyond constructed legs — every test calls the helper
/// directly and asserts on the returned types.
@Suite("IntraAccountSwapDetector")
struct IntraAccountSwapDetectorTests {
  private static let accountId = UUID(
    uuidString: "00000000-0000-0000-0000-00000000A111")!
  private static let ethereum = ChainConfig.ethereum.nativeInstrument
  private static let polygon = ChainConfig.polygon.nativeInstrument
  private static let base = ChainConfig.base.nativeInstrument

  @Test("2-token swap (1 in, 1 out, distinct instruments) → both retyped to .trade")
  func twoTokenSwapRetypesBothLegs() {
    let inbound = DirectionalLeg(
      leg: TransactionLeg(
        accountId: Self.accountId,
        instrument: Self.ethereum,
        quantity: 10,
        externalId: "0xhash:0",
        counterpartyAddress: "0xrouter",
        type: .income),
      direction: .inbound)
    let outbound = DirectionalLeg(
      leg: TransactionLeg(
        accountId: Self.accountId,
        instrument: Self.polygon,
        quantity: -20,
        externalId: "0xhash:1",
        counterpartyAddress: "0xrouter",
        type: .expense),
      direction: .outbound)

    let result = IntraAccountSwapDetector.retypeSwapLegs([inbound, outbound])

    #expect(result.count == 2)
    #expect(result.allSatisfy { $0.type == .trade })
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
mkdir -p .agent-tmp
just test-mac IntraAccountSwapDetectorTests 2>&1 | tee .agent-tmp/test-output.txt
```

Expected: build failure — `IntraAccountSwapDetector` and `DirectionalLeg` don't exist yet.

- [ ] **Step 3: Write the minimal implementation**

Create `Shared/CryptoImport/IntraAccountSwapDetector.swift`:

```swift
// Shared/CryptoImport/IntraAccountSwapDetector.swift
import Foundation

/// Pairs a per-event transfer leg with the direction it took relative
/// to the synced wallet. Used by `IntraAccountSwapDetector` so the
/// detector can distinguish a real inbound (`.inbound`) from a
/// self-send (`.selfSend`) without inferring from
/// `counterpartyAddress`.
struct DirectionalLeg: Sendable {
  let leg: TransactionLeg
  let direction: TransferDirection
}

/// Pure rewrite stage: when a hash group on a single account
/// represents an intra-account token swap (≥1 inbound + ≥1 outbound
/// non-fee leg, ≥2 distinct instruments across them), retype every
/// inbound and outbound leg from `.income` / `.expense` to `.trade`.
/// Otherwise return the input unchanged.
///
/// Self-send legs (`.selfSend`) and any defensively-handled
/// `.unrelated` legs are passed through untouched in their original
/// positions; their type stays whatever the builder assigned (per the
/// existing `legType(for:)` mapping `.selfSend` → `.income`).
///
/// The detector preserves order: each input position is kept; only
/// the `type` of inbound / outbound legs may be rewritten. All other
/// fields (id, accountId, instrument, quantity, externalId,
/// counterpartyAddress, categoryId, earmarkId) are preserved
/// verbatim.
///
/// Gas legs are not handled here — `TransferReceiptCoalescer.makeGasLeg`
/// runs after the detector and produces the `.expense` `:gas` leg
/// unchanged.
enum IntraAccountSwapDetector {
  static func retypeSwapLegs(_ directional: [DirectionalLeg]) -> [TransactionLeg] {
    let inbound = directional.filter { $0.direction == .inbound }
    let outbound = directional.filter { $0.direction == .outbound }
    guard !inbound.isEmpty, !outbound.isEmpty else {
      return directional.map(\.leg)
    }
    let instruments = Set(inbound.map(\.leg.instrument))
      .union(outbound.map(\.leg.instrument))
    guard instruments.count >= 2 else {
      return directional.map(\.leg)
    }
    return directional.map { item in
      switch item.direction {
      case .inbound, .outbound:
        var leg = item.leg
        leg.type = .trade
        return leg
      case .selfSend, .unrelated:
        return item.leg
      }
    }
  }
}
```

- [ ] **Step 4: Regenerate the Xcode project and re-run the test**

```bash
just generate
just test-mac IntraAccountSwapDetectorTests 2>&1 | tee .agent-tmp/test-output.txt
```

Expected: PASS for `twoTokenSwapRetypesBothLegs`. Fix compile errors before moving on (the most likely is `Instrument` not being `Hashable` — it is, so this should compile clean).

- [ ] **Step 5: Format and commit**

```bash
just format
git -C . add Shared/CryptoImport/IntraAccountSwapDetector.swift \
  MoolahTests/Shared/CryptoImport/IntraAccountSwapDetectorTests.swift
git -C . commit -m "$(cat <<'EOF'
feat(crypto): add IntraAccountSwapDetector with 2-token retype

Introduces a pure helper that retypes per-account import legs from
.income / .expense to .trade when the hash represents an intra-account
swap (≥1 inbound + ≥1 outbound, ≥2 distinct instruments). Self-send
legs pass through untouched. Initial test covers the canonical 2-token
case; further edge-case tests follow.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Edge cases — pure direction, same instrument, empty

**Files:**
- Modify: `MoolahTests/Shared/CryptoImport/IntraAccountSwapDetectorTests.swift`

The detector implementation from Task 1 already handles these — this task is purely about adding the regression coverage so the predicate boundaries are pinned.

- [ ] **Step 1: Write the failing tests**

Append the following tests to the `IntraAccountSwapDetectorTests` suite (inside the struct, after the existing test):

```swift
@Test("Pure inbound (no outbound) → unchanged")
func pureInboundUnchanged() {
  let inbound = DirectionalLeg(
    leg: TransactionLeg(
      accountId: Self.accountId,
      instrument: Self.ethereum,
      quantity: 10,
      externalId: "0xhash:0",
      type: .income),
    direction: .inbound)

  let result = IntraAccountSwapDetector.retypeSwapLegs([inbound])

  #expect(result.count == 1)
  #expect(result.first?.type == .income)
}

@Test("Pure outbound (no inbound) → unchanged")
func pureOutboundUnchanged() {
  let outbound = DirectionalLeg(
    leg: TransactionLeg(
      accountId: Self.accountId,
      instrument: Self.ethereum,
      quantity: -10,
      externalId: "0xhash:0",
      type: .expense),
    direction: .outbound)

  let result = IntraAccountSwapDetector.retypeSwapLegs([outbound])

  #expect(result.count == 1)
  #expect(result.first?.type == .expense)
}

@Test("Same instrument both sides (no third token) → unchanged")
func sameInstrumentBothSidesUnchanged() {
  let inbound = DirectionalLeg(
    leg: TransactionLeg(
      accountId: Self.accountId,
      instrument: Self.ethereum,
      quantity: 100,
      externalId: "0xhash:0",
      type: .income),
    direction: .inbound)
  let outbound = DirectionalLeg(
    leg: TransactionLeg(
      accountId: Self.accountId,
      instrument: Self.ethereum,
      quantity: -50,
      externalId: "0xhash:1",
      type: .expense),
    direction: .outbound)

  let result = IntraAccountSwapDetector.retypeSwapLegs([inbound, outbound])

  #expect(result.count == 2)
  #expect(result.map(\.type) == [.income, .expense])
}

@Test("Empty input → empty output")
func emptyInputUnchanged() {
  let result = IntraAccountSwapDetector.retypeSwapLegs([])
  #expect(result.isEmpty)
}
```

- [ ] **Step 2: Run tests to verify they pass**

```bash
just test-mac IntraAccountSwapDetectorTests 2>&1 | tee .agent-tmp/test-output.txt
```

Expected: all four new tests pass (the implementation already covers them via the empty-partition guard and the 2-distinct-instrument guard).

- [ ] **Step 3: Format and commit**

```bash
just format
git -C . add MoolahTests/Shared/CryptoImport/IntraAccountSwapDetectorTests.swift
git -C . commit -m "$(cat <<'EOF'
test(crypto): pin IntraAccountSwapDetector predicate boundaries

Adds regression coverage for pure-inbound, pure-outbound, same-
instrument-both-sides, and empty inputs — every shape the detector
must leave untouched.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Multi-leg shapes — 3-leg basket, LP add

**Files:**
- Modify: `MoolahTests/Shared/CryptoImport/IntraAccountSwapDetectorTests.swift`

- [ ] **Step 1: Write the failing tests**

Append:

```swift
@Test("3-leg basket trade (1 in, 2 out, 3 instruments) → all retyped to .trade")
func threeLegBasketTradeRetypesAll() {
  let inbound = DirectionalLeg(
    leg: TransactionLeg(
      accountId: Self.accountId,
      instrument: Self.ethereum,
      quantity: 5,
      externalId: "0xhash:0",
      type: .income),
    direction: .inbound)
  let outboundA = DirectionalLeg(
    leg: TransactionLeg(
      accountId: Self.accountId,
      instrument: Self.polygon,
      quantity: -10,
      externalId: "0xhash:1",
      type: .expense),
    direction: .outbound)
  let outboundB = DirectionalLeg(
    leg: TransactionLeg(
      accountId: Self.accountId,
      instrument: Self.base,
      quantity: -3,
      externalId: "0xhash:2",
      type: .expense),
    direction: .outbound)

  let result = IntraAccountSwapDetector.retypeSwapLegs([inbound, outboundA, outboundB])

  #expect(result.count == 3)
  #expect(result.allSatisfy { $0.type == .trade })
}

@Test("LP add shape (2 outbound, 1 inbound LP token) → all retyped to .trade")
func lpAddShapeRetypesAll() {
  let outboundA = DirectionalLeg(
    leg: TransactionLeg(
      accountId: Self.accountId,
      instrument: Self.ethereum,
      quantity: -1,
      externalId: "0xhash:0",
      type: .expense),
    direction: .outbound)
  let outboundB = DirectionalLeg(
    leg: TransactionLeg(
      accountId: Self.accountId,
      instrument: Self.polygon,
      quantity: -100,
      externalId: "0xhash:1",
      type: .expense),
    direction: .outbound)
  let inboundLP = DirectionalLeg(
    leg: TransactionLeg(
      accountId: Self.accountId,
      instrument: Self.base,
      quantity: 1,
      externalId: "0xhash:2",
      type: .income),
    direction: .inbound)

  let result = IntraAccountSwapDetector.retypeSwapLegs([outboundA, outboundB, inboundLP])

  #expect(result.count == 3)
  #expect(result.allSatisfy { $0.type == .trade })
}
```

- [ ] **Step 2: Run to verify**

```bash
just test-mac IntraAccountSwapDetectorTests 2>&1 | tee .agent-tmp/test-output.txt
```

Expected: both new tests pass.

- [ ] **Step 3: Format and commit**

```bash
just format
git -C . add MoolahTests/Shared/CryptoImport/IntraAccountSwapDetectorTests.swift
git -C . commit -m "$(cat <<'EOF'
test(crypto): cover 3-leg basket and LP-add swap shapes

The detector treats any mixed-direction hash with ≥2 distinct
instruments as a swap, so 3-leg baskets (1 in + 2 out) and LP-add
shapes (2 out + 1 in) retype every value-bearing leg to .trade. These
shapes don't satisfy Transaction.isTrade (which requires exactly 2
trade legs) but the legs are still typed correctly; downstream
consumers handle n-leg trade-typed transactions uniformly.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Self-send co-existence

**Files:**
- Modify: `MoolahTests/Shared/CryptoImport/IntraAccountSwapDetectorTests.swift`

- [ ] **Step 1: Write the failing tests**

Append:

```swift
@Test("Self-send + swap pair → self-send stays .income, swap legs retyped")
func selfSendCoexistsWithSwap() {
  let selfSend = DirectionalLeg(
    leg: TransactionLeg(
      accountId: Self.accountId,
      instrument: Self.ethereum,
      quantity: 5,
      externalId: "0xhash:0",
      counterpartyAddress: nil,
      type: .income),
    direction: .selfSend)
  let inbound = DirectionalLeg(
    leg: TransactionLeg(
      accountId: Self.accountId,
      instrument: Self.polygon,
      quantity: 10,
      externalId: "0xhash:1",
      counterpartyAddress: "0xrouter",
      type: .income),
    direction: .inbound)
  let outbound = DirectionalLeg(
    leg: TransactionLeg(
      accountId: Self.accountId,
      instrument: Self.base,
      quantity: -1,
      externalId: "0xhash:2",
      counterpartyAddress: "0xrouter",
      type: .expense),
    direction: .outbound)

  let result = IntraAccountSwapDetector.retypeSwapLegs([selfSend, inbound, outbound])

  #expect(result.count == 3)
  // Order preserved: selfSend at [0], inbound at [1], outbound at [2].
  #expect(result[0].type == .income)
  #expect(result[1].type == .trade)
  #expect(result[2].type == .trade)
}

@Test("Self-send only (no inbound or outbound) → unchanged")
func selfSendOnlyUnchanged() {
  let selfSend = DirectionalLeg(
    leg: TransactionLeg(
      accountId: Self.accountId,
      instrument: Self.ethereum,
      quantity: 5,
      externalId: "0xhash:0",
      type: .income),
    direction: .selfSend)

  let result = IntraAccountSwapDetector.retypeSwapLegs([selfSend])

  #expect(result.count == 1)
  #expect(result.first?.type == .income)
}
```

- [ ] **Step 2: Run to verify**

```bash
just test-mac IntraAccountSwapDetectorTests 2>&1 | tee .agent-tmp/test-output.txt
```

Expected: both new tests pass. The detector already filters by `direction == .inbound` / `.outbound`, so self-sends drop out of the predicate input. A self-send-only input has empty inbound/outbound → trips the `!inbound.isEmpty, !outbound.isEmpty` guard → returns unchanged.

- [ ] **Step 3: Format and commit**

```bash
just format
git -C . add MoolahTests/Shared/CryptoImport/IntraAccountSwapDetectorTests.swift
git -C . commit -m "$(cat <<'EOF'
test(crypto): preserve self-send legs through swap detector

A self-send (same wallet on both sides of an Alchemy transfer) carries
positive quantity and `.income` type, but isn't part of a swap and
shouldn't be retyped. Verifies self-send legs co-existing with a swap
pair stay .income, and a self-send-only hash trips the empty-
partition guard and is returned unchanged.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Field and order preservation

**Files:**
- Modify: `MoolahTests/Shared/CryptoImport/IntraAccountSwapDetectorTests.swift`

- [ ] **Step 1: Write the failing tests**

Append:

```swift
@Test("Field preservation: id, externalId, counterparty, category, earmark, quantity")
func retypePreservesEveryFieldExceptType() {
  let categoryId = UUID()
  let earmarkId = UUID()
  let inbound = DirectionalLeg(
    leg: TransactionLeg(
      id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
      accountId: Self.accountId,
      instrument: Self.ethereum,
      quantity: 10,
      externalId: "0xhash:0",
      counterpartyAddress: "0xrouter-in",
      type: .income,
      categoryId: categoryId,
      earmarkId: earmarkId),
    direction: .inbound)
  let outbound = DirectionalLeg(
    leg: TransactionLeg(
      id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
      accountId: Self.accountId,
      instrument: Self.polygon,
      quantity: -20,
      externalId: "0xhash:1",
      counterpartyAddress: "0xrouter-out",
      type: .expense),
    direction: .outbound)

  let result = IntraAccountSwapDetector.retypeSwapLegs([inbound, outbound])

  #expect(result.count == 2)
  let inboundResult = try! #require(result.first { $0.id == inbound.leg.id })
  #expect(inboundResult.type == .trade)
  #expect(inboundResult.accountId == Self.accountId)
  #expect(inboundResult.instrument == Self.ethereum)
  #expect(inboundResult.quantity == Decimal(10))
  #expect(inboundResult.externalId == "0xhash:0")
  #expect(inboundResult.counterpartyAddress == "0xrouter-in")
  #expect(inboundResult.categoryId == categoryId)
  #expect(inboundResult.earmarkId == earmarkId)

  let outboundResult = try! #require(result.first { $0.id == outbound.leg.id })
  #expect(outboundResult.type == .trade)
  #expect(outboundResult.quantity == Decimal(-20))
  #expect(outboundResult.counterpartyAddress == "0xrouter-out")
}

@Test("Input order is preserved on the output")
func orderPreserved() {
  let outbound = DirectionalLeg(
    leg: TransactionLeg(
      accountId: Self.accountId,
      instrument: Self.polygon,
      quantity: -20,
      externalId: "0xhash:0",
      type: .expense),
    direction: .outbound)
  let inbound = DirectionalLeg(
    leg: TransactionLeg(
      accountId: Self.accountId,
      instrument: Self.ethereum,
      quantity: 10,
      externalId: "0xhash:1",
      type: .income),
    direction: .inbound)

  let result = IntraAccountSwapDetector.retypeSwapLegs([outbound, inbound])

  #expect(result.count == 2)
  #expect(result[0].externalId == "0xhash:0")  // outbound first
  #expect(result[1].externalId == "0xhash:1")  // inbound second
  #expect(result.allSatisfy { $0.type == .trade })
}
```

- [ ] **Step 2: Run to verify**

```bash
just test-mac IntraAccountSwapDetectorTests 2>&1 | tee .agent-tmp/test-output.txt
```

Expected: both pass.

- [ ] **Step 3: Format and commit**

```bash
just format
git -C . add MoolahTests/Shared/CryptoImport/IntraAccountSwapDetectorTests.swift
git -C . commit -m "$(cat <<'EOF'
test(crypto): pin field- and order-preservation in swap retype

Locks in that the only field the detector touches is `type` — id,
accountId, instrument, quantity, externalId, counterpartyAddress,
categoryId, earmarkId all round-trip verbatim. Also pins input order
preservation so signpost / snapshot tests downstream stay
deterministic.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Wire detector into `TransferEventBuilder`

**Files:**
- Modify: `Shared/CryptoImport/TransferEventBuilder.swift`

This is the single integration point. `makeTransferLeg` returns a `DirectionalLeg?` instead of a `TransactionLeg?`, and `buildEvent` calls the detector before appending the gas leg. No existing public API changes; behaviour for non-swap hashes is identical.

- [ ] **Step 1: Update `makeTransferLeg` to return `DirectionalLeg?`**

In `Shared/CryptoImport/TransferEventBuilder.swift`, replace the `makeTransferLeg` body's return statement and signature:

```swift
private func makeTransferLeg(
  event: AlchemyTransfer,
  context: BuildContext
) async throws -> DirectionalLeg? {
  guard event.category != .unknown else {
    Self.logger.notice(
      "Skipping unknown-category transfer hash \(event.hash, privacy: .private)"
    )
    return nil
  }

  let direction = TransferDirection(
    fromAddress: event.from,
    toAddress: event.to,
    walletAddress: context.walletAddress)
  guard direction != .unrelated else {
    Self.logger.notice(
      "Skipping transfer not involving wallet for hash \(event.hash, privacy: .private)"
    )
    return nil
  }

  guard
    let unsignedQuantity = scaledQuantity(
      rawDecimalValue: event.rawContract.rawDecimalValue,
      decimalsValue: event.rawContract.decimalsValue,
      category: event.category,
      chain: context.chain)
  else {
    Self.logger.notice(
      "Skipping malformed-amount transfer hash \(event.hash, privacy: .private)"
    )
    return nil
  }

  let instrument = try await resolveInstrument(event: event, context: context)
  guard
    let resolution = signAndCounterparty(
      direction: direction, event: event, magnitude: unsignedQuantity)
  else {
    return nil
  }

  let leg = TransactionLeg(
    accountId: context.account.id,
    instrument: instrument,
    quantity: resolution.signedQuantity,
    externalId: event.uniqueId,
    counterpartyAddress: resolution.counterpartyAddress,
    type: TransferEventBuilder.legType(for: direction))
  return DirectionalLeg(leg: leg, direction: direction)
}
```

- [ ] **Step 2: Update `buildEvent` to consume `[DirectionalLeg]`**

Replace the `buildEvent` body in the same file:

```swift
private func buildEvent(
  events: [AlchemyTransfer],
  receipt: AlchemyTransactionReceipt?,
  context: BuildContext
) async throws -> BuiltTransaction? {
  var directional: [DirectionalLeg] = []
  var earliestTimestamp: Date?

  for event in events {
    try Task.checkCancellation()
    guard let item = try await makeTransferLeg(event: event, context: context) else {
      continue
    }
    directional.append(item)
    if let timestamp = parseTimestamp(event.metadata.blockTimestamp) {
      if let current = earliestTimestamp {
        earliestTimestamp = min(current, timestamp)
      } else {
        earliestTimestamp = timestamp
      }
    }
  }

  guard !directional.isEmpty else { return nil }

  var legs = IntraAccountSwapDetector.retypeSwapLegs(directional)

  if let receipt,
    let gasLeg = TransferReceiptCoalescer.makeGasLeg(
      receipt: receipt, accountId: context.account.id, chain: context.chain)
  {
    legs.append(gasLeg)
  }

  let date = earliestTimestamp ?? context.importOrigin.importedAt
  let transaction = Transaction(
    date: date,
    legs: legs,
    importOrigin: context.importOrigin)
  return BuiltTransaction(
    originAccountId: context.account.id,
    transaction: transaction)
}
```

- [ ] **Step 3: Run the existing builder test suite to verify no regression**

```bash
just test-mac TransferEventBuilder 2>&1 | tee .agent-tmp/test-output.txt
grep -E '^Test (Case|Suite).*(failed|passed)' .agent-tmp/test-output.txt | tail -40
```

Expected: every existing builder test still passes. If any test fails because it previously exercised an incidental swap shape, **stop** and proceed to Task 7 to audit before fixing.

- [ ] **Step 4: Format and commit**

```bash
just format
git -C . add Shared/CryptoImport/TransferEventBuilder.swift
git -C . commit -m "$(cat <<'EOF'
refactor(crypto): route per-event legs through swap detector

Changes makeTransferLeg to return DirectionalLeg?; buildEvent now
collects [DirectionalLeg], hands them to IntraAccountSwapDetector
before appending the gas leg, and returns the rewritten leg list.
Non-swap hashes keep their existing .income / .expense typing — the
detector returns its input unchanged when the predicate doesn't hold.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Audit existing builder tests for incidental swap shapes

**Files:**
- Modify (audit): `MoolahTests/Shared/CryptoImport/TransferEventBuilderTests.swift`
- Modify (audit): `MoolahTests/Shared/CryptoImport/TransferEventBuilderGasLegTests.swift`
- Modify (audit): `MoolahTests/Shared/CryptoImport/TransferEventBuilderConcurrencyTests.swift`
- Modify (audit): `MoolahTests/Shared/CryptoImport/TransferEventBuilderCounterpartyTests.swift`
- Modify (audit): `MoolahTests/Shared/CryptoImport/TransferEventBuilderGasAttributionTests.swift`
- Modify (audit): `MoolahTests/Shared/CryptoImport/TransferEventBuilderGasCoalescingTests.swift`
- Modify (audit): `MoolahTests/Shared/CryptoImport/TransferEventBuilderNativeRegTests.swift`

Most existing tests use a single transfer per hash and won't trigger the predicate. The exception is any test that builds **one inbound and one outbound transfer on the same hash for the same wallet across two distinct instruments** — that's now a swap and the assertions on `.income` / `.expense` will fail.

- [ ] **Step 1: Run the full builder suite (already done in Task 6 if Step 3 passed cleanly)**

If Task 6 / Step 3 was clean: this task is a no-op verification — skip to Step 3.

If anything failed, capture the output:

```bash
just test-mac TransferEventBuilder 2>&1 | tee .agent-tmp/test-output.txt
grep -B2 -A10 'failed\b' .agent-tmp/test-output.txt
```

- [ ] **Step 2: For each failing test, decide**

For each failing assertion, ask: does the test fixture produce a swap shape on a single account?

- **Yes**: the test was implicitly relying on legs being typed `.income`/`.expense`. Update the assertion to expect `.trade` (and to check the right leg by `externalId`, not by `type` if the test was using `type` as the discriminator). Add a one-line code comment that this hash is a swap shape.
- **No**: the test is a real regression — investigate.

Because every test in Task 6's existing suites uses single-hash + single-wallet + single-direction (or single-hash + multi-event in same direction, e.g. coalescing), expect zero failures here in practice.

- [ ] **Step 3: Re-run and commit any fixes**

```bash
just test-mac TransferEventBuilder 2>&1 | tee .agent-tmp/test-output.txt
just format
# Only run these if any audit changes were made:
git -C . add MoolahTests/Shared/CryptoImport/
git -C . commit -m "$(cat <<'EOF'
test(crypto): adjust builder tests that incidentally produced swap shapes

Aligns the existing TransferEventBuilder test fixtures with the new
intra-account swap retype: any case that paired a same-hash inbound
and outbound across distinct instruments now expects .trade legs
instead of .income / .expense.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

If no changes were needed, skip the commit. **Do not commit an empty changelog entry.**

---

## Task 8: Integration tests against `TransferEventBuilder.build(...)`

**Files:**
- Create: `MoolahTests/Shared/CryptoImport/TransferEventBuilderSwapTests.swift`

These tests exercise the full builder pipeline (transfer-leg construction + receipt fetch + detector + gas-leg append) for swap shapes.

- [ ] **Step 1: Write the integration tests**

Create `MoolahTests/Shared/CryptoImport/TransferEventBuilderSwapTests.swift`:

```swift
// MoolahTests/Shared/CryptoImport/TransferEventBuilderSwapTests.swift
import Foundation
import Testing

@testable import Moolah

/// Integration tests for `TransferEventBuilder` covering intra-account
/// token-swap detection. Pairs same-hash inbound and outbound transfers
/// for one wallet across distinct instruments and asserts the produced
/// transaction's legs are typed `.trade`, with the gas leg (if any) left
/// as `.expense`.
@Suite("TransferEventBuilder — intra-account swap")
struct TransferEventBuilderSwapTests {
  private static let wallet = "0x1111111111111111111111111111111111111111"
  private static let counterparty = "0x2222222222222222222222222222222222222222"
  private static let usdcAddress = "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"
  private static let proveAddress = "0xb0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"

  // 21_000 gas * 1.5 gwei = 0.0000315 ETH
  private static let gasUsed = Decimal(21_000)
  private static let gasPrice = Decimal(1_500_000_000)
  private static let expectedGasFeeEth = Decimal(string: "0.0000315") ?? 0

  @Test("ETH out + ERC-20 in (no receipt) → 2 .trade legs, no gas leg, isTrade==true")
  func twoTokenSwapWithoutReceiptProducesTradeLegs() async throws {
    let subject = makeDiscoverySubject()
    subject.resolver.script(
      .init(chainId: 1, contractAddress: Self.usdcAddress.lowercased()),
      .success(coingecko: "usd-coin", cryptocompare: nil, binance: nil))

    let account = makeCryptoAccount(walletAddress: Self.wallet, chain: .ethereum)
    let origin = makeWalletImportOrigin(for: account.id)
    // 1 ETH outbound (1 * 10^18 wei).
    let ethOut = makeAlchemyTransfer(
      hash: "0xswap",
      from: Self.wallet,
      to: Self.counterparty,
      category: .external,
      uniqueIdSuffix: "0")
    // 100 USDC inbound (100 * 10^6).
    let usdcIn = makeAlchemyTransfer(
      hash: "0xswap",
      from: Self.counterparty,
      to: Self.wallet,
      category: .erc20,
      asset: "USDC",
      contractAddress: Self.usdcAddress,
      decimalsHex: "0x6",
      rawValueHex: "0x5f5e100",
      uniqueIdSuffix: "1")

    let built = try await TransferEventBuilder().build(
      transfers: [ethOut, usdcIn],
      account: account,
      services: BuilderServices(
        chain: .ethereum,
        discovery: subject.service,
        alchemy: ZeroReceiptAlchemyStub()),
      importOrigin: origin)

    let candidate = try #require(built.first)
    let legs = candidate.transaction.legs
    #expect(legs.count == 2)
    #expect(legs.allSatisfy { $0.type == .trade })
    #expect(candidate.transaction.isTrade)
  }

  @Test("ETH out + ERC-20 in + receipt → 2 .trade + 1 .expense gas, isTrade==true")
  func twoTokenSwapWithReceiptIncludesGasLeg() async throws {
    let subject = makeDiscoverySubject()
    subject.resolver.script(
      .init(chainId: 1, contractAddress: Self.usdcAddress.lowercased()),
      .success(coingecko: "usd-coin", cryptocompare: nil, binance: nil))

    let alchemy = RecordingAlchemyClientStub()
    alchemy.setReceiptResponse(
      .receipt(
        AlchemyTransactionReceipt(
          hash: "0xswap",
          gasUsed: Self.gasUsed,
          effectiveGasPrice: Self.gasPrice,
          from: Self.wallet)),
      for: "0xswap")

    let account = makeCryptoAccount(walletAddress: Self.wallet, chain: .ethereum)
    let origin = makeWalletImportOrigin(for: account.id)
    let ethOut = makeAlchemyTransfer(
      hash: "0xswap", from: Self.wallet, to: Self.counterparty,
      category: .external, uniqueIdSuffix: "0")
    let usdcIn = makeAlchemyTransfer(
      hash: "0xswap", from: Self.counterparty, to: Self.wallet,
      category: .erc20, asset: "USDC",
      contractAddress: Self.usdcAddress,
      decimalsHex: "0x6", rawValueHex: "0x5f5e100",
      uniqueIdSuffix: "1")

    let built = try await TransferEventBuilder().build(
      transfers: [ethOut, usdcIn],
      account: account,
      services: BuilderServices(
        chain: .ethereum, discovery: subject.service, alchemy: alchemy),
      importOrigin: origin)

    let candidate = try #require(built.first)
    let legs = candidate.transaction.legs
    #expect(legs.count == 3)

    let tradeLegs = legs.filter { $0.type == .trade }
    let expenseLegs = legs.filter { $0.type == .expense }
    #expect(tradeLegs.count == 2)
    #expect(expenseLegs.count == 1)

    let gasLeg = try #require(expenseLegs.first)
    #expect(gasLeg.externalId == "0xswap:gas")
    #expect(gasLeg.instrument == ChainConfig.ethereum.nativeInstrument)
    #expect(gasLeg.quantity == -Self.expectedGasFeeEth)

    #expect(candidate.transaction.isTrade)
  }

  @Test("3-leg basket swap → 3 .trade legs + gas, isTrade==false")
  func threeLegBasketSwapKeepsAllTradeLegs() async throws {
    let subject = makeDiscoverySubject()
    subject.resolver.script(
      .init(chainId: 1, contractAddress: Self.usdcAddress.lowercased()),
      .success(coingecko: "usd-coin", cryptocompare: nil, binance: nil))
    subject.resolver.script(
      .init(chainId: 1, contractAddress: Self.proveAddress.lowercased()),
      .success(coingecko: "prove", cryptocompare: nil, binance: nil))

    let alchemy = RecordingAlchemyClientStub()
    alchemy.setReceiptResponse(
      .receipt(
        AlchemyTransactionReceipt(
          hash: "0xbasket",
          gasUsed: Self.gasUsed,
          effectiveGasPrice: Self.gasPrice,
          from: Self.wallet)),
      for: "0xbasket")

    let account = makeCryptoAccount(walletAddress: Self.wallet, chain: .ethereum)
    let origin = makeWalletImportOrigin(for: account.id)
    let ethOut = makeAlchemyTransfer(
      hash: "0xbasket", from: Self.wallet, to: Self.counterparty,
      category: .external, uniqueIdSuffix: "0")
    let usdcIn = makeAlchemyTransfer(
      hash: "0xbasket", from: Self.counterparty, to: Self.wallet,
      category: .erc20, asset: "USDC",
      contractAddress: Self.usdcAddress,
      decimalsHex: "0x6", rawValueHex: "0x5f5e100",
      uniqueIdSuffix: "1")
    let proveIn = makeAlchemyTransfer(
      hash: "0xbasket", from: Self.counterparty, to: Self.wallet,
      category: .erc20, asset: "PROVE",
      contractAddress: Self.proveAddress,
      decimalsHex: "0x12", rawValueHex: "0x0de0b6b3a7640000",
      uniqueIdSuffix: "2")

    let built = try await TransferEventBuilder().build(
      transfers: [ethOut, usdcIn, proveIn],
      account: account,
      services: BuilderServices(
        chain: .ethereum, discovery: subject.service, alchemy: alchemy),
      importOrigin: origin)

    let candidate = try #require(built.first)
    let legs = candidate.transaction.legs
    #expect(legs.count == 4)
    #expect(legs.filter { $0.type == .trade }.count == 3)
    #expect(legs.filter { $0.type == .expense }.count == 1)
    // 3 trade legs => Transaction.isTrade requires exactly 2 → false.
    #expect(!candidate.transaction.isTrade)
  }

  @Test("Pure inbound transfer → leg stays .income, no receipt fetch, no gas leg")
  func pureInboundLeavesIncome() async throws {
    let subject = makeDiscoverySubject()
    let alchemy = ZeroReceiptAlchemyStub()
    let account = makeCryptoAccount(walletAddress: Self.wallet, chain: .ethereum)
    let origin = makeWalletImportOrigin(for: account.id)
    let inbound = makeAlchemyTransfer(
      hash: "0xpure-inbound",
      from: Self.counterparty,
      to: Self.wallet,
      category: .external)

    let built = try await TransferEventBuilder().build(
      transfers: [inbound],
      account: account,
      services: BuilderServices(
        chain: .ethereum, discovery: subject.service, alchemy: alchemy),
      importOrigin: origin)

    let candidate = try #require(built.first)
    #expect(candidate.transaction.legs.count == 1)
    #expect(candidate.transaction.legs.first?.type == .income)
    #expect(alchemy.recordedReceiptCalls.isEmpty)
  }

  @Test("Pure outbound transfer (no inbound peer) → leg stays .expense + gas")
  func pureOutboundLeavesExpense() async throws {
    let subject = makeDiscoverySubject()
    let alchemy = RecordingAlchemyClientStub()
    alchemy.setReceiptResponse(
      .receipt(
        AlchemyTransactionReceipt(
          hash: "0xpure-out",
          gasUsed: Self.gasUsed,
          effectiveGasPrice: Self.gasPrice,
          from: Self.wallet)),
      for: "0xpure-out")
    let account = makeCryptoAccount(walletAddress: Self.wallet, chain: .ethereum)
    let origin = makeWalletImportOrigin(for: account.id)
    let outbound = makeAlchemyTransfer(
      hash: "0xpure-out",
      from: Self.wallet,
      to: Self.counterparty,
      category: .external)

    let built = try await TransferEventBuilder().build(
      transfers: [outbound],
      account: account,
      services: BuilderServices(
        chain: .ethereum, discovery: subject.service, alchemy: alchemy),
      importOrigin: origin)

    let candidate = try #require(built.first)
    let legs = candidate.transaction.legs
    #expect(legs.count == 2)
    #expect(legs.contains { $0.type == .expense && $0.externalId == "0xpure-out:0" })
    #expect(legs.contains { $0.type == .expense && $0.externalId == "0xpure-out:gas" })
  }
}
```

- [ ] **Step 2: Generate the project and run the new tests**

```bash
just generate
just test-mac TransferEventBuilderSwapTests 2>&1 | tee .agent-tmp/test-output.txt
```

Expected: all five tests pass.

- [ ] **Step 3: Format and commit**

```bash
just format
git -C . add MoolahTests/Shared/CryptoImport/TransferEventBuilderSwapTests.swift
git -C . commit -m "$(cat <<'EOF'
test(crypto): integration coverage for swap detection in builder

Exercises the full TransferEventBuilder.build() pipeline for swap
shapes: 2-token (with and without a receipt), 3-leg basket, plus
regression guards for pure inbound and pure outbound transfers. The
2-token case asserts Transaction.isTrade is true so downstream cost-
basis machinery lights up automatically; the 3-leg case asserts
isTrade is false (exactly-2 invariant unchanged) but the legs still
type as .trade.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: `CrossAccountTransferMerger` regression test

**Files:**
- Modify: `MoolahTests/Shared/CryptoImport/CrossAccountTransferMergerTests.swift`

The merger's `valueBearingTransferLeg` already filters to "exactly one `.income` or `.expense` leg with non-`:gas` `externalId`". A swap candidate has zero such legs after retype, so the merger naturally skips it. Pin that behaviour with one explicit assertion.

- [ ] **Step 1: Write the failing test**

Append to `CrossAccountTransferMergerTests` (inside the struct, before the closing `}`):

```swift
@Test("All-trade swap candidate passes through merger untouched")
func allTradeSwapCandidatePassesThrough() async throws {
  // Single-account 2-leg swap: both legs typed .trade, distinct instruments.
  let tradeIn = TransactionLeg(
    accountId: Self.accountA,
    instrument: TestInstruments.ethereum,
    quantity: 1,
    externalId: "\(Self.hash):0",
    type: .trade)
  let tradeOut = TransactionLeg(
    accountId: Self.accountA,
    instrument: TestInstruments.polygon,
    quantity: -100,
    externalId: "\(Self.hash):1",
    type: .trade)
  let swap = BuiltTransaction(
    originAccountId: Self.accountA,
    transaction: Transaction(
      date: Self.dateA,
      legs: [tradeIn, tradeOut],
      importOrigin: nil))

  let merged = try await LiveCrossAccountTransferMerger().merge(
    candidates: [swap],
    existingLegLookup: { _ in [] })

  #expect(merged.count == 1)
  let result = try #require(merged.first)
  #expect(result.transaction.legs.count == 2)
  // Untouched: still .trade on both legs.
  #expect(result.transaction.legs.allSatisfy { $0.type == .trade })
}
```

- [ ] **Step 2: Run to verify**

```bash
just test-mac CrossAccountTransferMergerTests 2>&1 | tee .agent-tmp/test-output.txt
```

Expected: passes (the merger's `valueBearingTransferLeg` returns nil for the swap, so the merger appends the candidate as-is).

- [ ] **Step 3: Format and commit**

```bash
just format
git -C . add MoolahTests/Shared/CryptoImport/CrossAccountTransferMergerTests.swift
git -C . commit -m "$(cat <<'EOF'
test(crypto): pin merger's pass-through for all-trade swap candidates

A swap candidate has zero .income or .expense non-:gas legs after the
intra-account retype, so the merger's valueBearingTransferLeg filter
returns nil and the candidate flows through unchanged. Locks in this
non-interaction so future merger changes don't accidentally pair swap
legs across accounts.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Format-check, full test run, code review, push, PR

- [ ] **Step 1: Run the full mac test suite**

```bash
just test-mac 2>&1 | tee .agent-tmp/test-mac.txt
grep -E '\bfailed\b|error:' .agent-tmp/test-mac.txt | head -20
tail -3 .agent-tmp/test-mac.txt
```

Expected: `** TEST SUCCEEDED **` on the final line. Investigate any failure before proceeding — do not push with red tests.

- [ ] **Step 2: Run `just format-check` (CI parity)**

```bash
just format-check 2>&1 | tee .agent-tmp/format-check.txt
```

Expected: exit 0, no diff output. If anything fails, fix the underlying code (do not edit `.swiftlint-baseline.yml`); re-run `just format` and commit any resulting changes.

- [ ] **Step 3: Run the `code-review` agent over the diff**

Invoke `@code-review` with the branch's full diff against `origin/fix/crypto-gas-attribution` for context. Apply every Critical / Important / Minor finding (per the `feedback_apply_all_review_findings` memory: don't dismiss, don't selectively skip; ask the user only if you genuinely want to defer).

```bash
git -C . diff origin/fix/crypto-gas-attribution...HEAD -- '*.swift' > .agent-tmp/branch-diff.patch
wc -l .agent-tmp/branch-diff.patch
```

Use the diff file as context when invoking the review agent.

- [ ] **Step 4: Run `concurrency-review` if any concurrency surfaces changed**

Only relevant if the audit in Task 7 changed any `@MainActor` / `Sendable` boundaries — the detector itself is pure / sync, so most likely no. Skip unless something concurrency-shaped moved.

- [ ] **Step 5: Push the branch (explicit src:dst form)**

The worktree was created with `--no-track`. Per CLAUDE.md, use the explicit destination form on the first push:

```bash
git -C . push origin feat/crypto-swap-trade-detection:feat/crypto-swap-trade-detection 2>&1 | tee .agent-tmp/push.txt
```

Verify the output reports a new branch on `origin`, not an update to `fix/crypto-gas-attribution`.

- [ ] **Step 6: Open the PR against `fix/crypto-gas-attribution`**

```bash
gh pr create \
  --base fix/crypto-gas-attribution \
  --head feat/crypto-swap-trade-detection \
  --title "feat(crypto): retype intra-account token-swap legs to .trade" \
  --body "$(cat <<'EOF'
## Summary

Stacked on PR #807. When a single on-chain hash represents an
intra-account token swap (≥1 inbound + ≥1 outbound non-fee leg, ≥2
distinct instruments), the wallet importer now retypes the per-event
legs from `.income` / `.expense` to `.trade`. Gas leg stays
`.expense`. Forward-only — existing imports keep their prior typing.

A new pure helper `IntraAccountSwapDetector` runs inside
`TransferEventBuilder.buildEvent` after per-event leg construction
and before the gas leg is appended. `Transaction.isTrade` and
`TradeEventClassifier` are deliberately not modified: the canonical
2-leg swap matches `isTrade` automatically and lights up FIFO cost
basis with the gas folded into per-unit cost; 3+ leg swaps stay
`.trade`-typed but don't auto-classify.

Spec: `plans/2026-05-08-crypto-swap-trade-detection-design.md`.

## Test plan

- [x] New `IntraAccountSwapDetectorTests` covering 2-leg swap, 3-leg
  basket, LP-add, pure-direction, same-instrument-both-sides,
  empty, self-send co-existence, and field/order preservation.
- [x] New `TransferEventBuilderSwapTests` covering 2-token (with /
  without receipt), 3-leg basket, pure inbound (no receipt fetch),
  pure outbound + gas.
- [x] Existing `TransferEventBuilder*Tests` still pass (no incidental
  swap shapes affected).
- [x] Added merger pass-through test for all-trade swap candidates.
- [x] `just test-mac` ✅ `** TEST SUCCEEDED **`.
- [x] `just format-check` clean.
- [x] `@code-review` agent clean.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)" 2>&1 | tee .agent-tmp/pr-create.txt
grep '^https://' .agent-tmp/pr-create.txt | head -1
```

Capture the PR URL from the output. Format it as a markdown link to `https://github.com/ajsutton/moolah-native/pull/N` per project memory.

- [ ] **Step 7: Add the PR to the merge queue**

Per the `feedback_prs_to_merge_queue` memory: every PR opened goes through the merge-queue skill. Invoke it after the PR is open, passing the PR number. Do not manually merge.

- [ ] **Step 8: Clean up `.agent-tmp/`**

```bash
rm -f .agent-tmp/test-output.txt .agent-tmp/test-mac.txt .agent-tmp/format-check.txt .agent-tmp/branch-diff.patch .agent-tmp/push.txt .agent-tmp/pr-create.txt
```

---

## Self-review checklist (after writing the plan)

- [x] Every spec section has at least one task: predicate (Tasks 1-5), gas leg interaction (Task 8), cross-account merger non-interaction (Task 9), backfill (no-op — verified by Task 6/Step 3), self-send (Task 4), field preservation (Task 5), 3+ leg shapes (Task 3, Task 8).
- [x] No placeholders, "TBD", or "similar to" cross-references — every step has the actual code or command.
- [x] Type names consistent: `DirectionalLeg` (struct, top-level), `IntraAccountSwapDetector.retypeSwapLegs(_:)`, `TransferDirection` (existing enum), `TransactionLeg.type` (existing var).
- [x] Test framework matches the project (Swift Testing — `@Suite`, `@Test`, `#expect`, `#require`).
- [x] Build / test commands match project (`just test-mac`, `just format`, `just format-check`, `just generate`).
- [x] Worktree push uses explicit `<src>:<dst>` form per CLAUDE.md stacked-PR rule.
- [x] PR base is `fix/crypto-gas-attribution` (PR #807), not `main`.
- [x] Merge-queue handoff included.
