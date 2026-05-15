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
///   Required to convert the raw value into a human-scaled `Decimal`.
/// - `rawContract.value` — exact integer-units value as a 0x-prefixed
///   hex string. Source-of-truth for arithmetic; the top-level `value`
///   field on the transfer is a lossy IEEE-754 representation that
///   rounds large amounts. Mapped onto the Swift property `rawValue`
///   via `CodingKeys` so the local name doesn't shadow the
///   `RawRepresentable.rawValue` requirement on neighbouring enums.
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
    /// present for transfers Alchemy returns. Decoded from JSON key
    /// `value` (the wire-format name) but bound to a Swift property
    /// called `rawValue` to keep call sites unambiguous next to `decimal`
    /// and to avoid shadowing the IEEE-754 top-level `value` field.
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

extension AlchemyTransfer.RawContract {
  /// Custom decoder so `rawValue` (the Swift property) reads from the
  /// `value` JSON key (Alchemy's actual wire-format name). An
  /// auto-synthesised conformance would read JSON key `rawValue`, which
  /// Alchemy never emits, so every transfer would decode with
  /// `rawValue == nil` and be dropped at
  /// `TransferEventBuilder.scaledQuantity`. Defined out-of-line so
  /// `RawContractCodingKeys` lives at file scope.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: RawContractCodingKeys.self)
    self.address = try container.decodeIfPresent(String.self, forKey: .address)
    self.decimal = try container.decodeIfPresent(String.self, forKey: .decimal)
    self.rawValue = try container.decodeIfPresent(String.self, forKey: .rawValue)
  }
}

/// Coding keys for `AlchemyTransfer.RawContract`. Lives at file scope
/// rather than nested inside the struct.
private enum RawContractCodingKeys: String, CodingKey {
  case address
  case decimal
  case rawValue = "value"
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
