# Crypto Swap → `.trade` Leg Detection — Design

## Context

The crypto wallet importer currently emits one `.income` leg per inbound
transfer and one `.expense` leg per outbound transfer for every Alchemy
transfer that touches a synced wallet, plus one `.expense` `:gas` leg
constructed from the receipt when this wallet is the sender. A token
swap (e.g. receiving 10 USDC and sending 20 PROVE in the same on-chain
hash) therefore lands as `.income` + `.expense` + `.expense (gas)`,
which is bookkeeping-incorrect: nothing was earned and nothing was
spent in the cash-flow sense — value was exchanged.

This change retypes the swap legs to `.trade` so that:

- The 2-token case matches `Transaction.isTrade`
  (Domain/Models/Transaction+Structure.swift) and lights up the trade
  detail UI and `TradeEventClassifier`'s FIFO buy/sell events
  automatically.
- 3+ leg swaps (basket trades, LP adds/removes) are still typed
  semantically correctly as `.trade` legs, even though they don't
  satisfy `isTrade` and won't auto-classify into cost-basis events
  (per explicit design choice — `isTrade` and `TradeEventClassifier`
  are not modified).

## Scope and non-goals

In scope:

- A pure intra-account, intra-hash detector that runs inside
  `TransferEventBuilder.buildEvent` and rewrites leg `.type` values
  before the gas leg is appended.
- Coverage of 2-leg, 3+ leg, mixed-direction, same-instrument-both-
  sides, self-send-co-existence, and pure-direction edge cases.
- Tests for the detector in isolation and integration tests through
  `TransferEventBuilder`.

Out of scope (explicitly):

- Modifying `Transaction.isTrade` or `TradeEventClassifier`.
- Backfilling existing `.income` / `.expense` legs imported on prior
  syncs. `survivingLegs` in `WalletApplyEngine` drops re-imports on
  matching `(accountId, externalId)`, so existing legs stay as-is.
  Mirrors PR #807's stance on already-misattributed gas legs: users
  can manually edit; a retroactive sweep is a separate effort.
- Cross-account swap detection. A swap by definition is one wallet
  exchanging two tokens; the existing `CrossAccountTransferMerger`
  remains the single channel for cross-account transfer pairing and
  naturally skips swap candidates (zero `.income` / `.expense`
  non-`:gas` legs after retype).
- Bridging transactions (two chains). v1 doesn't emit cross-chain
  legs; if a future bridge integration produces 1 outbound on chain A
  and 1 inbound on chain B, those will still be separate per-account
  candidates and route through the cross-account merger, not the
  swap detector.

## Architecture

A new file `Shared/CryptoImport/IntraAccountSwapDetector.swift`
exposes a single `enum`-namespaced helper:

```swift
enum IntraAccountSwapDetector {
  static func retypeSwapLegs(
    _ directional: [DirectionalLeg]
  ) -> [TransactionLeg]
}
```

Pure, synchronous, no captured state, no dependencies — directly unit
testable.

`TransferEventBuilder.makeTransferLeg` is changed to return
`DirectionalLeg?` (a tuple of `(leg: TransactionLeg, direction:
TransferDirection)`) so that the detector can distinguish a real
inbound (`.inbound`) from a self-send (`.selfSend`) without inferring
from `counterpartyAddress`. `DirectionalLeg` is a small private
struct in the CryptoImport module.

`TransferEventBuilder.buildEvent` integration:

```swift
var directional: [DirectionalLeg] = []
for event in events {
  try Task.checkCancellation()
  guard let item = try await makeTransferLeg(event: event, context: context)
  else { continue }
  directional.append(item)
  // ... earliestTimestamp accumulation as today ...
}

guard !directional.isEmpty else { return nil }

var legs = IntraAccountSwapDetector.retypeSwapLegs(directional)

if let receipt,
   let gasLeg = TransferReceiptCoalescer.makeGasLeg(...) {
  legs.append(gasLeg)
}

// ... Transaction construction unchanged ...
```

The detector runs once per hash group, before the gas leg is
appended. The gas leg path (`outboundHashes` → receipt fetch →
`makeGasLeg`) is unchanged; gas attribution from PR #807 still
applies.

## Predicate

Given `directional: [DirectionalLeg]` (one hash, one account, the
gas leg not yet appended):

1. Partition by `direction`:
   - `inbound = directional.filter { $0.direction == .inbound }`
   - `outbound = directional.filter { $0.direction == .outbound }`
   - `.selfSend` and (defensively) `.unrelated` legs are passed
     through untouched in their original positions.
2. Trigger conditions, both must hold:
   - `!inbound.isEmpty && !outbound.isEmpty`, **and**
   - `Set(inbound.map(\.leg.instrument))
       .union(Set(outbound.map(\.leg.instrument)))
       .count >= 2`
3. When the trigger fires, every `inbound` and `outbound` leg has
   `type` set to `.trade`. All other fields (`id`, `accountId`,
   `instrument`, `quantity`, `externalId`, `counterpartyAddress`,
   `categoryId`, `earmarkId`) are preserved verbatim.
4. Self-send legs in the same hash group are unchanged
   (stay `.income` per the existing `legType(for:)` mapping).
5. When the trigger does not fire, the input legs are returned with
   their original types (current behaviour).

The output preserves input order (each `DirectionalLeg`'s position
is kept; only `type` may be rewritten) so signpost and snapshot
tests stay deterministic.

### Worked examples

| Hash legs (this account) | Trigger? | Output types |
|---|---|---|
| `+10 USDC, -20 PROVE` | yes (1 in, 1 out, 2 instruments) | `.trade`, `.trade` (+ `.expense` `:gas`) |
| `+10 USDC, -20 PROVE, -1 USDT` | yes (1 in, 2 out, 3 instruments) | `.trade`, `.trade`, `.trade` (+ `.expense` `:gas`) |
| `+1 LP, -10 A, -5 B` (LP add) | yes (1 in, 2 out, 3 instruments) | `.trade`, `.trade`, `.trade` (+ `.expense` `:gas`) |
| `+100 USDC, -50 USDC` (no third token) | no (1 in, 1 out, 1 instrument) | `.income`, `.expense` (current) |
| `+10 USDC` only | no (no outbound) | `.income` (current) |
| `-20 PROVE` only | no (no inbound) | `.expense` (+ `.expense` `:gas`) (current) |
| selfSend `+5 USDC` + `+10 DAI, -20 PROVE` | yes (predicate ignores selfSend) | `.income` (selfSend), `.trade`, `.trade` (+ `.expense` `:gas`) |
| `[]` | no | `[]` |

## Pipeline interactions

- **Gas leg.** Untouched. `outboundHashes` already gates receipt
  fetches on "this wallet has at least one outbound transfer"; a
  swap satisfies that, so the receipt fetch happens, and `makeGasLeg`
  produces the same `.expense` `:gas` leg as today, appended after
  the detector runs. Sign convention preserved (`-gasFeeNative`).
- **Cross-account merger.** No change.
  `LiveCrossAccountTransferMerger.valueBearingTransferLeg` requires
  exactly one `.income` or `.expense` leg with non-`:gas`
  `externalId`. After retype a swap has zero such legs (everything
  is `.trade` or the `:gas` `.expense`), so the merger's
  `valueBearingTransferLeg` returns `nil` and the swap candidate
  passes through. Single-leg cross-account transfers are unaffected.
- **`survivingLegs` dedup in `WalletApplyEngine`.** Operates on
  `(accountId, externalId)`; leg type is irrelevant. Re-imports of
  hashes whose legs are already persisted with the old `.income` /
  `.expense` typing are dropped, so **the retype is forward-only**:
  new hashes land as `.trade`; previously imported hashes keep their
  prior typing. This is the explicit no-backfill stance.
- **`CrossDeviceLegDeduper`.** Operates on `(accountId, externalId)`;
  unaffected.
- **`Transaction.isTrade`.** Lights up automatically for the canonical
  2-leg case (2 `.trade` + 0..n `.expense`). 3+ leg swaps return
  `false` from `isTrade` — the legs persist as `.trade` but the
  transaction is not surfaced as a "trade transaction" by the
  `TransactionDetailView` / row UI.
- **`TradeEventClassifier`.** Returns empty for `tradeLegs.count !=
  2`, so 3+ leg swaps emit no FIFO events. 2-leg swaps generate
  cost-basis events identical to a manually entered trade, with the
  `:gas` `.expense` leg folded into per-unit cost via
  `feeContribution`. Same-instrument fast path applies if the gas
  instrument matches host currency.
- **`PositionBook` / `ProfitLossCalculator` / display amounts.** Already
  handle `.trade` legs uniformly (`Transaction+Structure.compute
  DisplayAmounts` sums per instrument across n legs). No change.

## Counterparty handling on retyped legs

The detector preserves `counterpartyAddress` verbatim. For a swap leg
that's the contract address of the router / pool / aggregator on the
"other side" of the on-chain transfer (`to` for outbound, `from` for
inbound). Manually entered `.trade` legs leave the field nil; importer-
emitted `.trade` legs carry it. The block-explorer click-through
(`BlockExplorerLink`) and the user-visible counterparty in the trade
detail UI both benefit from preserving the address, and nothing
downstream — including `TradeEventClassifier` — reads it.

## Backfill (out of scope)

`survivingLegs` in `WalletApplyEngine` drops a candidate leg when an
existing leg with the same `(accountId, externalId)` is already
persisted (Shared/CryptoImport/WalletApplyEngine.swift §`dedup`).
That guarantees re-syncing a previously imported hash will not
retype its existing legs — the new `.trade`-typed candidate is
dropped before persist.

Forward-only is the right default here:

- Migration would require `TransactionRepository` writes that flow
  through CKSyncEngine to other devices; multi-device convergence on
  retype during a sync cycle is non-trivial.
- The semantics of "is this hash a swap?" depend on the predicate
  above; running it over historical legs needs care to handle
  partial syncs and shape changes.
- Mirrors PR #807's stance on already-misattributed gas legs.

Users who want past swaps reclassified can edit them manually. A
retroactive sweep is tracked as future work.

## Testing strategy

### `MoolahTests/Shared/CryptoImport/IntraAccountSwapDetectorTests.swift`

Pure unit tests over `[DirectionalLeg] → [TransactionLeg]`. No async,
no fixtures beyond constructed legs. Cases:

- 2-token swap (1 in, 1 out, 2 instruments) → both retyped to
  `.trade`.
- 3-leg basket (1 in, 2 out, 3 instruments) → all retyped to `.trade`.
- LP add shape (1 in, 2 out, 3 instruments) → all retyped.
- Same instrument both sides (no third token) → unchanged.
- All inbound only → unchanged.
- All outbound only → unchanged.
- Empty input → empty output.
- Self-send + swap pair → self-send stays `.income`; swap legs
  retyped.
- Self-send + same-instrument-only inbound (no outbound elsewhere)
  → unchanged.
- Field preservation: sign, quantity, instrument, externalId,
  counterpartyAddress, categoryId, earmarkId preserved verbatim on
  retyped legs.
- Order preservation: input order retained.

### `MoolahTests/Shared/CryptoImport/TransferEventBuilderSwapTests.swift`

Integration cases that exercise `buildEvent` end-to-end with
synthetic Alchemy fixtures:

- 2-token swap, no receipt → 2 `.trade` legs, no gas leg,
  `Transaction.isTrade == true`.
- 2-token swap with receipt → 2 `.trade` legs + 1 `.expense` `:gas`
  leg, `isTrade == true`, `TradeEventClassifier.classify` produces
  one buy + one sell with gas folded into cost via `feeContribution`.
- 3-leg swap with receipt → 3 `.trade` legs + 1 `.expense` `:gas`
  leg, `isTrade == false`, legs persist as `.trade`.
- Pure outbound transfer (no inbound, no swap predicate) → leg stays
  `.expense`, gas leg appended (regression guard).
- Pure inbound transfer (no outbound) → leg stays `.income`, no
  receipt fetch, no gas leg.
- Cross-account transfer shape (this account contributes one side of
  the pair) → leg stays `.income` / `.expense` so the cross-account
  merger still pairs it (regression guard).

### `MoolahTests/Shared/CryptoImport/CrossAccountTransferMergerTests.swift` (extension)

A single small assertion: a candidate whose legs have all been
retyped to `.trade` (i.e. a swap) passes through the merger
untouched — no spurious cross-account pairing.

No UI tests, no benchmark additions — the detector is a tiny pure
step (one partition, one set union, one optional rewrite per leg)
on a hot path that's already dominated by the receipt-fetch
round-trip.

## Files touched

- New: `Shared/CryptoImport/IntraAccountSwapDetector.swift`
- New: `MoolahTests/Shared/CryptoImport/IntraAccountSwapDetectorTests.swift`
- New: `MoolahTests/Shared/CryptoImport/TransferEventBuilderSwapTests.swift`
- Modified: `Shared/CryptoImport/TransferEventBuilder.swift`
  (`makeTransferLeg` returns `DirectionalLeg?`; `buildEvent` calls
  the detector before appending the gas leg).
- Modified: `Shared/CryptoImport/TransferEventBuilder+NativeRegistration.swift`
  (no behavioural change; `legType(for:)` may be inlined or kept as-is
  depending on call-site cleanliness — confirmed during implementation).
- Extended: `MoolahTests/Shared/CryptoImport/CrossAccountTransferMergerTests.swift`
  (one new assertion).

Existing `TransferEventBuilderTests.swift` may need fixture updates
where prior outbound + inbound combos on the same account in the same
hash incidentally exercised the old `.income` / `.expense` typing — the
implementation step audits and updates as needed.

## Open questions

None at design time.
