// MoolahTests/Backends/GRDB/PerProfileInstrumentMapResolverTests.swift

import GRDB
import Testing

@testable import Moolah

@Suite("PerProfileInstrumentMapResolver reads the per-profile instrument table")
struct PerProfileInstrumentMapResolverTests {
  @Test("returns rows from the supplied per-profile database")
  func readsPerProfileTable() async throws {
    let queue = try DatabaseQueue()
    try ProfileSchema.migrator.migrate(queue)
    try await queue.write { database in
      try InstrumentRow(
        domain: Instrument.crypto(
          chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
      ).insert(database)
    }
    let resolver = PerProfileInstrumentMapResolver(database: queue)
    let map = try await resolver.instrumentMap()
    #expect(map["1:native"]?.kind == .cryptoToken)
  }
}
