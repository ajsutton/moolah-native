// MoolahTests/Backends/CloudKit/ProfileIndexInstrumentTestSupport.swift

@preconcurrency import CloudKit
import Foundation
import GRDB

@testable import Moolah

/// Shared test fixture for the InstrumentRecord dispatch tests on the
/// profile-index zone. Centralises the migrated `DatabaseQueue`, both
/// repositories, and the handler so the dispatch tests stay focused
/// on assertions.
enum ProfileIndexInstrumentTestSupport {
  struct Harness: ~Copyable {
    let queue: DatabaseQueue
    let profileRepo: GRDBProfileIndexRepository
    let registry: GRDBInstrumentRegistryRepository
    let handler: ProfileIndexSyncHandler

    init(onInstrumentRemoteChange: @escaping @Sendable () -> Void = {}) throws {
      self.queue = try ProfileIndexDatabase.openInMemory()
      self.profileRepo = GRDBProfileIndexRepository(database: queue)
      self.registry = GRDBInstrumentRegistryRepository(database: queue)
      self.handler = ProfileIndexSyncHandler(
        repository: profileRepo,
        instrumentRepository: registry,
        onInstrumentRemoteChange: onInstrumentRemoteChange)
    }
  }

  /// Builds a synthetic CKRecord of type `InstrumentRecord` for use as
  /// a saved-records fixture or a server-side conflict record.
  static func makeInstrumentRecord(
    in zoneID: CKRecordZone.ID,
    id: String = "1:0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
    name: String = "USD Coin",
    pricingStatus: String = "priced",
    coingeckoId: String? = "usd-coin"
  ) -> CKRecord {
    let recordID = CKRecord.ID(recordName: id, zoneID: zoneID)
    let record = CKRecord(recordType: InstrumentRow.recordType, recordID: recordID)
    record["kind"] = "cryptoToken"
    record["name"] = name
    record["decimals"] = 6 as Int64
    record["chainId"] = 1 as Int64
    record["contractAddress"] = "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"
    record["coingeckoId"] = coingeckoId
    record["pricingStatus"] = pricingStatus
    return record
  }
}
