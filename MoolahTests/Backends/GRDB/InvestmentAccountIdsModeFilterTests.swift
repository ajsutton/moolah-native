// MoolahTests/Backends/GRDB/InvestmentAccountIdsModeFilterTests.swift
import Foundation
import GRDB
import Testing

@testable import Moolah

/// `fetchInvestmentAccountIds` must not surface trades-mode investment
/// accounts. The daily-balance snapshot fold owns recorded-value
/// accounts only; trades-mode accounts get their per-day value from a
/// different (planned) path. Pinning this filter at the SQL boundary
/// keeps the snapshot loader from leaking trades-mode ids into the
/// fold, which would overwrite the calculated value with a stale or
/// missing snapshot.
@Suite("fetchInvestmentAccountIds filters by mode")
struct InvestmentAccountIdsModeFilterTests {
  @Test("only recordedValue investment accounts are returned")
  func filtersByMode() throws {
    let queue = try DatabaseQueue()
    try ProfileSchema.migrator.migrate(queue)
    let recordedId = UUID()
    let tradesId = UUID()
    let bankId = UUID()
    try queue.write { database in
      for (id, type, mode) in [
        (recordedId, "investment", "recordedValue"),
        (tradesId, "investment", "calculatedFromTrades"),
        (bankId, "bank", "recordedValue"),
      ] {
        try database.execute(
          sql: """
            INSERT INTO account
              (id, record_name, name, type, instrument_id, position,
               is_hidden, valuation_mode)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
          arguments: [id, "AccountRecord|\(id)", "n", type, "AUD", 0, 0, mode])
      }
    }
    let ids = try queue.read { database in
      try GRDBAnalysisRepository.fetchInvestmentAccountIds(database: database)
    }
    #expect(ids == [recordedId])
  }
}
