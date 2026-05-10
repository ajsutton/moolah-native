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
    let snapshot = try await queue.read { database in
      try (
        InstrumentRow.fetchAll(database),
        CryptoPriceRecord.fetchAll(database),
        StockPriceRecord.fetchAll(database),
        ExchangeRateRecord.fetchAll(database),
        CryptoTokenMetaRecord.fetchAll(database),
        StockTickerMetaRecord.fetchAll(database),
        ExchangeRateMetaRecord.fetchAll(database)
      )
    }
    self.instruments = snapshot.0
    self.cryptoPrices = snapshot.1
    self.stockPrices = snapshot.2
    self.exchangeRates = snapshot.3
    self.cryptoTokenMeta = snapshot.4
    self.stockTickerMeta = snapshot.5
    self.exchangeRateMeta = snapshot.6
  }
}
