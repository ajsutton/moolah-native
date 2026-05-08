// Shared/CryptoImport/AlchemyTransactionReceipt.swift
import Foundation

/// Decoded subset of Alchemy `eth_getTransactionReceipt` response.
/// Used to compute the gas leg on outbound transfers — Alchemy's
/// transfer endpoint doesn't include gas-cost data per transfer, so
/// the wallet sync pipeline fetches the receipt for any unique
/// outbound `txHash`.
///
/// `gasUsed` is the actual amount of gas consumed (post-execution).
/// `effectiveGasPrice` is the per-gas price actually paid (post-EIP-1559
/// — handles base fee + priority tip). Multiplying gives wei spent on gas.
///
/// Both fields decode from `0x`-prefixed hex strings; we normalise to
/// `Decimal` to preserve precision (256-bit values overflow `UInt64`).
struct AlchemyTransactionReceipt: Sendable, Hashable {
  /// On-chain transaction hash (`0x`-prefixed). Used by the builder to
  /// key receipts back to the originating event.
  let hash: String
  /// Gas units actually consumed by the transaction. Decoded from the
  /// `gasUsed` 0x-hex field on the receipt.
  let gasUsed: Decimal
  /// Effective per-gas price actually paid in wei. Decoded from the
  /// `effectiveGasPrice` 0x-hex field; covers both base fee and priority
  /// tip post-EIP-1559.
  let effectiveGasPrice: Decimal
  /// EOA that signed the on-chain transaction (lowercased). Sourced from
  /// the `from` field on `eth_getTransactionReceipt`. The gas-leg
  /// builder compares this against the synced wallet address — gas is
  /// only attributed to a wallet that signed the outer tx. An `.internal`
  /// or `erc20 transferFrom` row can have `transfer.from == wallet`
  /// while `receipt.from` is a different EOA; that wallet did not pay
  /// gas and gets no `:gas` leg.
  let from: String

  /// `gasUsed * effectiveGasPrice` in wei. Caller divides by
  /// `10 ** chain.nativeInstrument.decimals` to get native units.
  var totalGasFeeWei: Decimal {
    gasUsed * effectiveGasPrice
  }
}

/// Lenient `0x`-prefixed hex parser shared by the `AlchemyClient`
/// receipt decoder and the `AlchemyTransfer.RawContract` value
/// accessors. Returns `nil` on malformed input so callers can log and
/// skip without failing the whole sync.
///
/// `Decimal` is the target type because 256-bit on-chain integers
/// overflow `UInt64` (gas-fee products in particular routinely exceed
/// 64 bits once `gasUsed * effectiveGasPrice` lands in wei).
enum HexDecimal {
  /// Parses a 0x-prefixed (or unprefixed) hex string into a `Decimal`.
  /// Returns `nil` on empty input or any non-hex character.
  static func parse(_ string: String) -> Decimal? {
    let trimmed = stripHexPrefix(string)
    guard !trimmed.isEmpty else { return nil }
    var result: Decimal = 0
    for char in trimmed {
      guard let nibble = char.hexDigitValue else { return nil }
      result = result * 16 + Decimal(nibble)
    }
    return result
  }

  /// Parses a 0x-prefixed hex string into an `Int`. Returns `nil` on
  /// malformed input or values that exceed `Int.max`.
  static func parseInt(_ string: String) -> Int? {
    let trimmed = stripHexPrefix(string)
    return Int(trimmed, radix: 16)
  }

  private static func stripHexPrefix(_ string: String) -> String {
    string.hasPrefix("0x") || string.hasPrefix("0X")
      ? String(string.dropFirst(2))
      : string
  }
}
