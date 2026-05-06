// Shared/CryptoImport/AlchemyTransfer.swift
import Foundation

/// One entry from Alchemy's `alchemy_getAssetTransfers` response.
///
/// Stage 4 only decodes — the transformation to `BuiltTransaction` is
/// Stage 6's job. All fields needed by later stages are preserved here:
///
/// - `hash` / `uniqueId` — used as the `externalId` for de-duplication
///   across two-pass `fromAddress` / `toAddress` queries.
/// - `from` / `to` — required for cross-account transfer detection.
/// - `category` — distinguishes native, internal, and ERC-20 transfers
///   (NFT categories are filtered at request time and not represented).
/// - `asset` — the human-readable token symbol from Alchemy. Best-effort;
///   may differ from the canonical CoinGecko symbol.
/// - `rawContract.address` — `nil` for native transfers; the ERC-20
///   contract address otherwise. Used as part of the instrument key.
/// - `rawContract.decimal` — token decimals as a 0x-prefixed hex string.
///   Required to convert `rawValue` into a human-scaled `Decimal`.
/// - `rawContract.rawValue` — exact integer-units value as a 0x-prefixed
///   hex string. Source-of-truth for arithmetic; the JSON `value` field
///   is a lossy IEEE-754 representation that rounds large amounts.
/// - `metadata.blockTimestamp` — ISO-8601 timestamp of the block that
///   contains this transfer. Used for the transaction date.
/// - `blockNum` — 0x-prefixed hex block number; persisted as the
///   `lastSyncedBlock` watermark.
struct AlchemyTransfer: Sendable, Hashable, Decodable {
  let hash: String
  let uniqueId: String
  let from: String
  let to: String?
  let category: AlchemyTransferCategory
  let asset: String?
  let rawContract: RawContract
  let metadata: Metadata
  let blockNum: String

  /// Inner `rawContract` object. Hex-encoded fields are kept as strings —
  /// callers that need numeric values use the `decimalValue` and
  /// `decimalsValue` helpers, both of which return `nil` rather than
  /// throwing on malformed input (so a single bad row doesn't fail the
  /// whole sync).
  struct RawContract: Sendable, Hashable, Decodable {
    /// Contract address (`nil` for native-token transfers).
    let address: String?
    /// 0x-prefixed hex of the token decimals (e.g. `"0x12"` = 18). May
    /// be missing on native transfers — Alchemy then omits the field.
    let decimal: String?
    /// 0x-prefixed hex of the integer-units transfer amount. Always
    /// present for transfers Alchemy returns.
    let rawValue: String?

    /// Parses `decimal` from 0x-hex into an `Int`. Returns `nil` if the
    /// field is missing or malformed. Defers to `HexDecimal.parseInt`.
    var decimalsValue: Int? {
      decimal.flatMap { HexDecimal.parseInt($0) }
    }

    /// Parses `rawValue` from 0x-hex into a `Decimal`. Returns `nil` if
    /// the field is missing or malformed. `Decimal` is used because
    /// 256-bit token amounts overflow `UInt64`. Defers to
    /// `HexDecimal.parse`.
    var rawDecimalValue: Decimal? {
      rawValue.flatMap { HexDecimal.parse($0) }
    }
  }

  /// Inner `metadata` object. Alchemy provides `blockTimestamp` only when
  /// the request sets `withMetadata: true`.
  struct Metadata: Sendable, Hashable, Decodable {
    /// ISO-8601 block timestamp (e.g. `"2024-09-12T12:34:56.000Z"`).
    let blockTimestamp: String?
  }
}

/// Subset of Alchemy's transfer categories we accept.
///
/// NFT categories (`erc721`, `erc1155`, `specialnft`) are deliberately
/// filtered at the request level — we never request them. The `unknown`
/// case keeps decoding lenient: if a future Alchemy release introduces a
/// new category, callers can filter it out without crashing the sync.
enum AlchemyTransferCategory: String, Sendable, Hashable, Codable {
  case external
  case `internal`
  case erc20
  /// Defensive default — covers any unrecognised string Alchemy might
  /// return (including NFT categories that slip through despite the
  /// request-level filter).
  case unknown

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let raw = try container.decode(String.self)
    self = AlchemyTransferCategory(rawValue: raw) ?? .unknown
  }
}
