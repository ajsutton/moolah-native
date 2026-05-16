// Shared/CryptoImport/BlockscoutTransferAdapter.swift
import Foundation
import OSLog

/// One signed transaction the wallet paid gas for, with the block
/// timestamp needed to date a gas-only transaction (one with no value
/// transfer of its own — `approve()`, failed, zero-movement). This is
/// the authoritative gas set that fixes #919: it includes every tx
/// where the wallet is the sender, regardless of value or status.
struct SignedGasTx: Sendable, Hashable {
  let hash: String
  let blockTimestamp: Date
}

/// Result of normalising Blockscout rows into the existing pipeline
/// model.
struct BlockscoutAdaptResult: Sendable {
  let transfers: [AlchemyTransfer]
  let signedGasTxs: [SignedGasTx]
}

/// Pure adapter: Blockscout native + internal rows → `AlchemyTransfer`s
/// (Alchemy-format `uniqueId`s so cross-account merge / per-leg dedup /
/// `externalId` indexing are reused unchanged) plus the signed-tx set.
/// Stateless and `Sendable`.
enum BlockscoutTransferAdapter {
  private static let logger = Logger(
    subsystem: "com.moolah.app", category: "BlockscoutTransferAdapter")

  /// `walletAddress` is expected pre-lowercased by the caller
  /// (`WalletSyncEngine` passes `account.walletAddress.lowercased()`),
  /// but every comparison re-lowercases defensively — Blockscout
  /// returns checksummed addresses.
  static func adapt(
    nativeTxs: [BlockscoutTransaction],
    internalTxs: [BlockscoutInternalTx],
    walletAddress rawWallet: String,
    chain: ChainConfig
  ) -> BlockscoutAdaptResult {
    let wallet = rawWallet.lowercased()
    var transfers: [AlchemyTransfer] = []
    var signed: [SignedGasTx] = []
    var seenSignedHashes: Set<String> = []

    for tx in nativeTxs {
      let from = tx.from.hash.lowercased()
      let to = tx.to?.hash.lowercased()
      // Authoritative gas set: every tx the wallet signed, regardless
      // of value / status (#919). Dedup by hash, preserve first-seen.
      if from == wallet, seenSignedHashes.insert(tx.hash).inserted {
        signed.append(
          SignedGasTx(
            hash: tx.hash,
            blockTimestamp: parseTimestamp(tx.timestamp) ?? Date(timeIntervalSince1970: 0)))
      }
      // Value leg only for non-zero transfers that touch the wallet.
      guard let weiHex = decimalStringToHexWei(tx.value), weiHex != "0x0" else { continue }
      guard from == wallet || to == wallet else { continue }
      transfers.append(
        makeTransfer(
          hash: tx.hash, uniqueId: "\(tx.hash):external:0",
          category: .external, from: tx.from.hash, to: tx.to?.hash,
          weiHex: weiHex, block: tx.blockNumber, timestamp: tx.timestamp))
    }

    for itx in internalTxs {
      let from = itx.from.hash.lowercased()
      let to = itx.to?.hash.lowercased()
      guard let weiHex = decimalStringToHexWei(itx.value), weiHex != "0x0" else { continue }
      guard from == wallet || to == wallet else { continue }
      transfers.append(
        makeTransfer(
          hash: itx.transactionHash,
          uniqueId: "\(itx.transactionHash):internal:\(itx.index)",
          category: .internal, from: itx.from.hash, to: itx.to?.hash,
          weiHex: weiHex, block: itx.blockNumber, timestamp: itx.timestamp))
    }

    return BlockscoutAdaptResult(transfers: transfers, signedGasTxs: signed)
  }

  // MARK: - Internals

  private static func makeTransfer(
    hash: String, uniqueId: String, category: AlchemyTransferCategory,
    from: String, to: String?, weiHex: String, block: Int, timestamp: String?
  ) -> AlchemyTransfer {
    AlchemyTransfer(
      hash: hash,
      uniqueId: uniqueId,
      from: from,
      to: to,
      category: category,
      asset: nil,
      rawContract: AlchemyTransfer.RawContract(
        address: nil, decimal: nil, rawValue: weiHex),
      metadata: AlchemyTransfer.Metadata(blockTimestamp: timestamp),
      blockNum: "0x" + String(UInt64(block.magnitude), radix: 16))
  }

  /// Blockscout `value` is a base-10 wei string. The builder consumes a
  /// `0x`-hex `rawValue` (`HexDecimal.parse`), so convert. Returns
  /// `"0x0"` for "0"; `nil` on non-numeric input (row logged + skipped).
  static func decimalStringToHexWei(_ decimalString: String) -> String? {
    let trimmed = decimalString.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, trimmed.allSatisfy(\.isNumber) else {
      logger.notice("Skipping Blockscout row — non-numeric value")
      return nil
    }
    if trimmed.allSatisfy({ $0 == "0" }) { return "0x0" }
    var value = Decimal(string: trimmed) ?? 0
    guard value > 0 else { return "0x0" }
    var digits = ""
    let sixteen = Decimal(16)
    while value > 0 {
      let remainder = value - (value / sixteen).rounded(.down) * sixteen
      let nibble = (remainder as NSDecimalNumber).intValue
      digits.append(Self.hexDigits[nibble])
      value = (value / sixteen).rounded(.down)
    }
    return "0x" + String(digits.reversed())
  }

  private static let hexDigits = Array("0123456789abcdef")

  /// ISO-8601 (Blockscout uses fractional seconds, e.g.
  /// `2024-09-12T12:34:56.000000Z`). Reuses the lenient policy: `nil`
  /// on unparseable input so a bad row degrades rather than fails.
  private static func parseTimestamp(_ raw: String?) -> Date? {
    guard let raw else { return nil }
    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = withFraction.date(from: raw) { return date }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: raw)
  }
}

extension Decimal {
  /// Truncates toward zero. Local helper for the wei→hex loop; kept
  /// fileprivate-equivalent by living next to its only caller.
  fileprivate func rounded(_ rule: FloatingPointRoundingRule) -> Decimal {
    var input = self
    var result = Decimal()
    NSDecimalRound(&result, &input, 0, rule == .down ? .down : .plain)
    return result
  }
}
