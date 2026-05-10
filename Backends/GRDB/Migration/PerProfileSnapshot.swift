// Backends/GRDB/Migration/PerProfileSnapshot.swift

import Foundation
import GRDB

/// Snapshot of one per-profile DB consumed by
/// `SharedRegistryUnionRunner` (`App/`). Lives here in `Backends/GRDB/`
/// because all seven stored properties are GRDB record types — keeping
/// the type at the backend layer preserves `CODE_GUIDE.md` §3 / `CLAUDE.md`
/// "Domain Layer: strictly isolated" rule (records never leave
/// `Backends/GRDB/`). The runner imports `GRDB` for its own merge
/// SQL anyway, so co-locating doesn't impose a new module dependency
/// — it just stops App-layer code from naming `InstrumentRow` /
/// `CryptoPriceRecord` / etc. directly.
///
/// `Database` handles never escape the read closure; the snapshot is a
/// `Sendable` value type so it can cross the per-profile-queue
/// boundary into the shared-DB write transaction without leaking the
/// connection.
struct PerProfileSnapshot: Sendable {
  let profileId: UUID
  let instruments: [InstrumentRow]
  let cryptoPrices: [CryptoPriceRecord]
  let stockPrices: [StockPriceRecord]
  let exchangeRates: [ExchangeRateRecord]
  let cryptoTokenMeta: [CryptoTokenMetaRecord]
  let stockTickerMeta: [StockTickerMetaRecord]
  let exchangeRateMeta: [ExchangeRateMetaRecord]

  /// Reads every relevant table from the per-profile queue into Swift
  /// value types so the snapshot can be passed to the shared-DB write
  /// transaction without a live `Database` handle escaping.
  init(profileId: UUID, queue: DatabaseQueue) async throws {
    self.profileId = profileId
    // Named-field intermediate avoids the `.0`–`.6` positional
    // destructure pattern — swapping any two `fetchAll` lines below
    // would silently misassign fields with the tuple form.
    let raw = try await queue.read(Self.fetchRaw(_:))
    self.instruments = raw.instruments
    self.cryptoPrices = raw.cryptoPrices
    self.stockPrices = raw.stockPrices
    self.exchangeRates = raw.exchangeRates
    self.cryptoTokenMeta = raw.cryptoTokenMeta
    self.stockTickerMeta = raw.stockTickerMeta
    self.exchangeRateMeta = raw.exchangeRateMeta
  }

  /// Captures the seven `fetchAll` results as a named-field struct so
  /// the closure body can't accidentally swap the assignment order
  /// (the previous 7-element anonymous-tuple form was positional).
  /// Local to the snapshot so no other file can construct one.
  private struct RawFetch: Sendable {
    let instruments: [InstrumentRow]
    let cryptoPrices: [CryptoPriceRecord]
    let stockPrices: [StockPriceRecord]
    let exchangeRates: [ExchangeRateRecord]
    let cryptoTokenMeta: [CryptoTokenMetaRecord]
    let stockTickerMeta: [StockTickerMetaRecord]
    let exchangeRateMeta: [ExchangeRateMetaRecord]
  }

  private static func fetchRaw(_ database: Database) throws -> RawFetch {
    RawFetch(
      instruments: try InstrumentRow.fetchAll(database),
      cryptoPrices: try CryptoPriceRecord.fetchAll(database),
      stockPrices: try StockPriceRecord.fetchAll(database),
      exchangeRates: try ExchangeRateRecord.fetchAll(database),
      cryptoTokenMeta: try CryptoTokenMetaRecord.fetchAll(database),
      stockTickerMeta: try StockTickerMetaRecord.fetchAll(database),
      exchangeRateMeta: try ExchangeRateMetaRecord.fetchAll(database))
  }
}
