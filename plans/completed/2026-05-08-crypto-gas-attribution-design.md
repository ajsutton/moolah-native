# Crypto Gas Attribution — Design

**Date:** 2026-05-08
**Branch:** `fix/crypto-native-conversion`

## Problem

`TransferEventBuilder` currently attributes a `:gas` expense leg to a
wallet whenever any non-NFT Alchemy transfer in the hash group has
`from.lowercased() == walletAddress`. That heuristic over-attributes
gas in two real-world cases:

1. **Internal transfers driven by someone else's outer transaction.** A
   contract called by another EOA can produce an `internal` transfer
   whose `from` is our wallet (e.g. a contract with prior approval moves
   our funds). Our wallet did not sign the outer transaction, so it did
   not pay gas.
2. **ERC-20 `transferFrom` initiated by a router or third party.** A DEX
   router with token approval pulls tokens from our wallet on someone
   else's call. Alchemy reports the `erc20` row with `from = wallet`,
   but the EOA that signed the transaction (and paid gas) is whoever
   called the router.

Inbound-only groups are already handled correctly: no row has
`from == wallet`, so the receipt is not fetched and no gas leg is
emitted.

The "don't double-count gas if multiple transfers occur within the same
transaction" property is already provided by `groupByHash` —
one receipt per hash, one `:gas` leg per hash. This design preserves
that property.

## Goal

Emit a `:gas` leg for a hash group **iff** the EOA that signed the
on-chain transaction matches `account.walletAddress`. Use
`eth_getTransactionReceipt`'s `from` field as the source of truth.

## Non-Goals

- Tightening the receipt-fetch heuristic. The current heuristic
  (`outboundHashes`) over-fetches in the third-party-`transferFrom`
  case but never under-fetches; that's an acceptable cost. Gating the
  `:gas` leg post-fetch is sufficient and keeps the change small.
- Changing transfer-leg construction, dedup, `externalId` schemes, or
  the cross-account merger. None of those participate in the bug.

## Design

### Behaviour

A `:gas` leg is appended to a hash group's transaction iff:

```
receipt != nil
  && receipt.from.lowercased() == account.walletAddress.lowercased()
  && receipt.totalGasFeeWei > 0
```

If `receipt.from` does not match the wallet, `makeGasLeg` returns
`nil` and the transaction ships without a gas leg. The non-gas
transfer legs are unaffected.

### Cases

| Scenario | Receipt fetched? | `receipt.from` | Gas leg? |
|---|---|---|---|
| Wallet sends ETH to Alice (top-level) | Yes | wallet | Yes |
| Wallet sends USDC (top-level `transfer()`) | Yes | wallet | Yes |
| Alice sends ETH to wallet | No (heuristic skips) | n/a | No |
| Alice's contract internally moves wallet funds out | Yes | Alice | **No** (was incorrectly Yes) |
| Router pulls tokens via `transferFrom(wallet, …)` | Yes | router caller | **No** (was incorrectly Yes) |
| Self-send (wallet → wallet) | Yes | wallet | Yes |
| Outbound multi-leg tx (e.g. swap with N legs, signed by wallet) | Yes (once) | wallet | Yes (once) |

### Components

- `Shared/CryptoImport/AlchemyTransactionReceipt.swift`
  - Add `let from: String` to `AlchemyTransactionReceipt`. Lowercased
    at construction so call sites do not re-normalise.
- `Shared/CryptoImport/AlchemyJSONRPCWireFormat.swift`
  - `AlchemyTransactionReceiptPayload`: add `let from: String` decoded
    from the JSON `from` key.
  - `toReceipt(hash:)`: lowercase `from` and pass through. A
    missing/empty `from` surfaces as
    `WalletSyncError.providerMalformedResponse(stage: "getTransactionReceipt")`,
    matching the existing failure path for malformed receipts.
- `Shared/CryptoImport/TransferReceiptCoalescer.swift`
  - `makeGasLeg(receipt:accountId:chain:walletAddress:)`: new parameter
    `walletAddress: String` (caller passes the already-lowercased
    `BuildContext.walletAddress`). Return `nil` when
    `receipt.from != walletAddress`. Existing zero-fee guard preserved.
- `Shared/CryptoImport/TransferEventBuilder.swift`
  - `buildEvent`: pass `context.walletAddress` to `makeGasLeg`. No
    other change.
- `outboundHashes` (in `TransferReceiptCoalescer`): **unchanged.**
  The heuristic remains a conservative "fetch when a row plausibly
  implicates this wallet" filter. Authority for the gas-leg decision
  moves to `makeGasLeg`.

### Data flow

```
groupByHash(transfers)
  → outboundHashes (unchanged heuristic over transfer.from)
    → fetchReceipts (parallel, per hash — unchanged)
      → for each hash group:
          buildEvent
            transfer legs (unchanged)
            + makeGasLeg(receipt, accountId, chain, walletAddress)
                ├─ receipt.from == walletAddress → emit `:gas` leg
                └─ otherwise                      → nil (drop)
```

### Error handling

- Receipt JSON missing `from` → existing decode path raises
  `WalletSyncError.providerMalformedResponse(stage: "getTransactionReceipt")`.
  Per-receipt error containment in `fetchOne` already converts a
  `WalletSyncError` into a logged `notice` and a dropped gas leg, so a
  single malformed receipt does not fail the whole account.
- Receipt fetched but `from` mismatch → `makeGasLeg` returns `nil`.
  No log. This is a correctness outcome, not an error.

### Sign convention

Unchanged. Gas leg quantity stays negative (expense paid out). Per
CLAUDE.md "Monetary Sign Convention" we do not `abs()`-strip the sign.

## Testing

### `TransferEventBuilderGasLegTests` — new tests

1. **Internal transfer where wallet is `from` but signer is someone
   else → no gas leg.** Receipt's `from = counterparty`. Built
   transaction has only the inbound/transfer leg, no `:gas` leg.
2. **ERC-20 `transferFrom` style — token row's `from = wallet`,
   receipt's `from = router` → no gas leg.** Transfer leg still
   produced; `:gas` suffix absent.
3. **Mixed-category group where wallet signs (external + erc20
   outbound, both `from = wallet`, receipt's `from = wallet`) → one
   `:gas` leg.** Confirms the existing multi-leg coalescing still
   yields exactly one gas leg after the change.

### `TransferEventBuilderGasLegTests` — existing tests

Update each `AlchemyTransactionReceipt(...)` literal to set
`from: <wallet>`. Behaviour expectations unchanged.

### `TransferEventBuilderGasCoalescingTests`

Update receipt fixtures to include `from`. Coalescing assertions
(receipt-fetch counts) unchanged.

### `AlchemyTransactionReceiptDecodingTests`

- Add: real-shape JSON with `from` populated decodes to a receipt with
  the lowercased `from`.
- Add: JSON missing `from` surfaces as
  `WalletSyncError.providerMalformedResponse`.

### Live-client tests

`LiveAlchemyClientReceiptTests` — extend the canned-response fixtures
to include `from`, assert the decoded value flows through.

## Migration / Compatibility

No persisted-data change. `TransactionLeg` schema is untouched. The
`externalId` scheme (`<hash>:gas`) is unchanged, so previously imported
gas legs that were *incorrect* under the old logic are not auto-removed
— they remain on the user's transactions. A separate cleanup pass is
out of scope; users can manually delete any wrong gas leg, and the next
sync over the same hash will not re-emit it.

## Risk

- **Low.** The change is additive (one new field on a wire struct, one
  new parameter on `makeGasLeg`). Existing test fixtures need a small
  literal update. No production data layout changes.
- A receipt `from` field that Alchemy unexpectedly omits would surface
  as a decode failure; the existing per-receipt error containment
  prevents that from failing the whole account sync.
