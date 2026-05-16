// Shared/CryptoImport/TransferEventBuilder+GasOnly.swift
import Foundation

extension TransferEventBuilder {
  /// Performs the receipt-fetch + event-loop + gas-only pass after
  /// `build(_:)` has resolved the `BuildContext`. Separated to keep
  /// `build(_:)` under the function-body-length threshold while
  /// keeping the two phases (signpost/context setup vs. actual work)
  /// individually readable.
  func buildCore(
    transfers: [AlchemyTransfer],
    signedGasTxs: [SignedGasTx],
    context: BuildContext,
    alchemy: any AlchemyClient
  ) async throws -> [BuiltTransaction] {
    // Stable order: group preserves first-seen order so test fixtures
    // and signposts are deterministic.
    let groups = groupByHash(transfers)
    let receipts = try await TransferReceiptCoalescer.fetchReceipts(
      groups: groups,
      extraSignedHashes: signedGasTxs.map(\.hash),
      walletAddress: context.walletAddress,
      chain: context.chain,
      alchemy: alchemy)

    var results: [BuiltTransaction] = []
    results.reserveCapacity(groups.count)

    for events in groups {
      try Task.checkCancellation()
      let receipt = events.first.flatMap { receipts[$0.hash] }
      guard
        let built = try await buildEvent(
          events: events,
          receipt: receipt,
          context: context)
      else {
        continue
      }
      results.append(built)
    }

    let groupedHashes = Set(groups.compactMap { $0.first?.hash })
    results.append(
      contentsOf: try buildGasOnlyTransactions(
        signedGasTxs: signedGasTxs,
        groupedHashes: groupedHashes,
        receipts: receipts,
        context: context))
    return results
  }

  /// Builds gas-leg-only `BuiltTransaction`s for wallet-signed transactions
  /// that produced no transfer events — e.g. `approve()` calls, reverted
  /// txs, or contract interactions with zero token movement.
  ///
  /// Every transaction the wallet signed still paid gas, regardless of
  /// whether any `AlchemyTransfer` row exists for it. `signedGasTxs` carries
  /// the hashes from Blockscout's account tx list; `groupedHashes` is the
  /// set already covered by transfer-event groups so we don't double-emit.
  /// See https://github.com/ajsutton/moolah-native/issues/919.
  func buildGasOnlyTransactions(
    signedGasTxs: [SignedGasTx],
    groupedHashes: Set<String>,
    receipts: [String: AlchemyTransactionReceipt],
    context: BuildContext
  ) throws -> [BuiltTransaction] {
    var results: [BuiltTransaction] = []
    for signed in signedGasTxs where !groupedHashes.contains(signed.hash) {
      try Task.checkCancellation()
      guard
        let receipt = receipts[signed.hash],
        let gasLeg = TransferReceiptCoalescer.makeGasLeg(
          receipt: receipt,
          accountId: context.account.id,
          chain: context.chain,
          walletAddress: context.walletAddress)
      else {
        continue
      }
      let transaction = Transaction(
        date: signed.blockTimestamp,
        legs: [gasLeg],
        importOrigin: context.importOrigin)
      results.append(
        BuiltTransaction(
          originAccountId: context.account.id, transaction: transaction))
    }
    return results
  }
}
