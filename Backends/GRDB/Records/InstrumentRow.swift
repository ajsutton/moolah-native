// Backends/GRDB/Records/InstrumentRow.swift

import Foundation
import GRDB

/// One row in the `instrument` table — the GRDB-backed counterpart to the
/// SwiftData `@Model` `InstrumentRecord`.
///
/// **String primary key.** `Instrument` is the only synced row that
/// uses an arbitrary string ID (e.g. `"AUD"`, `"ASX:BHP"`,
/// `"1:0xa0b8…"`) instead of a UUID. The CloudKit recordName is the
/// bare `id` string with no `recordType|` prefix — see
/// `recordName(for:)`.
///
/// **Sync metadata.** `recordName` is the canonical CloudKit recordName
/// (the bare `id`). `encodedSystemFields` holds the cached CKRecord
/// change-tag blob; these bytes are bit-for-bit copies of what CloudKit
/// returned and are never decoded outside the sync boundary.
struct InstrumentRow {
  static let databaseTableName = "instrument"

  enum Columns: String, ColumnExpression, CaseIterable {
    case id
    case recordName = "record_name"
    case kind
    case name
    case decimals
    case ticker
    case exchange
    case chainId = "chain_id"
    case contractAddress = "contract_address"
    case coingeckoId = "coingecko_id"
    case cryptocompareSymbol = "cryptocompare_symbol"
    case binanceSymbol = "binance_symbol"
    case encodedSystemFields = "encoded_system_fields"
  }

  enum CodingKeys: String, CodingKey {
    case id
    case recordName = "record_name"
    case kind
    case name
    case decimals
    case ticker
    case exchange
    case chainId = "chain_id"
    case contractAddress = "contract_address"
    case coingeckoId = "coingecko_id"
    case cryptocompareSymbol = "cryptocompare_symbol"
    case binanceSymbol = "binance_symbol"
    case encodedSystemFields = "encoded_system_fields"
  }

  var id: String
  var recordName: String
  /// Raw value of `Instrument.Kind` (`"fiatCurrency"`, `"stock"`,
  /// `"cryptoToken"`). Pinned by a CHECK constraint; update both in
  /// lock-step if the enum's raw values change.
  var kind: String
  var name: String
  var decimals: Int
  var ticker: String?
  var exchange: String?
  var chainId: Int?
  var contractAddress: String?
  /// Provider-mapping fields — written by
  /// `InstrumentRegistryRepository.registerCrypto(_:mapping:)` /
  /// `registerStock(_:)`. Plain `Instrument` rows synthesised via
  /// `init(domain:)` carry `nil` here.
  var coingeckoId: String?
  var cryptocompareSymbol: String?
  var binanceSymbol: String?
  var encodedSystemFields: Data?
}

extension InstrumentRow: Codable {}
extension InstrumentRow: Sendable {}
extension InstrumentRow: Identifiable {}
extension InstrumentRow: FetchableRecord {}
extension InstrumentRow: PersistableRecord {}
