import Foundation
import GRDB

@testable import Moolah

// MARK: - Scale

/// Defines the scale multiplier for benchmark fixture generation.
struct BenchmarkScale: Sendable {
  let transactions: Int
  let accounts: Int
  let categories: Int
  let earmarks: Int
  let investmentValues: Int
  /// Number of accounts designated as investment type (placed at the end).
  let investmentAccounts: Int

  static let oneX = BenchmarkScale(
    transactions: 18_662,
    accounts: 31,
    categories: 158,
    earmarks: 21,
    investmentValues: 2_711,
    investmentAccounts: 6
  )

  static let twoX = BenchmarkScale(
    transactions: 37_324,
    accounts: 62,
    categories: 316,
    earmarks: 42,
    investmentValues: 5_422,
    investmentAccounts: 12
  )
}

// MARK: - BenchmarkFixtures

/// Generates realistic benchmark datasets matching the live iCloud profile distribution.
///
/// Real data profile (1x):
/// - 18,662 transactions across 31 accounts (top 3 hold ~85%)
/// - 158 categories, 21 earmarks, 2,711 investment values
/// - ~0.2% scheduled transactions
enum BenchmarkFixtures {

  // MARK: - Well-Known IDs

  /// The 3 heavy accounts that hold ~85% of transactions.
  /// Transaction distribution: ~38% heavy0, ~32% heavy1, ~16% heavy2, ~14% others.
  static let heavyAccountIds: [UUID] = [
    UUID(uuidString: "00000000-BE00-0000-0000-000000000001")!,
    UUID(uuidString: "00000000-BE00-0000-0000-000000000002")!,
    UUID(uuidString: "00000000-BE00-0000-0000-000000000003")!,
  ]

  /// The single busiest account (~38% of all transactions).
  static var heavyAccountId: UUID { heavyAccountIds[0] }

  // MARK: - Seeding

  /// Seeds a complete benchmark dataset into the given database.
  ///
  /// - Parameters:
  ///   - scale: The dataset scale (`.oneX` for real-data-sized, `.twoX` for double).
  ///   - database: An in-memory GRDB writer to populate.
  static func seed(scale: BenchmarkScale, in database: any DatabaseWriter) {
    let instrument = Instrument.defaultTestInstrument

    expecting("benchmark fixtures save failed") {
      try database.write { database in
        // Ensure the instrument row exists.
        try InstrumentRow(domain: instrument).insert(database)

        let accountIds = seedAccounts(scale: scale, database: database)
        let categoryIds = seedCategories(scale: scale, database: database)
        let earmarkIds = seedEarmarks(scale: scale, database: database, instrument: instrument)
        seedTransactions(
          scale: scale,
          ids: SeedIds(accounts: accountIds, categories: categoryIds, earmarks: earmarkIds),
          database: database,
          instrument: instrument
        )
        seedInvestmentValues(
          scale: scale,
          accountIds: accountIds,
          database: database,
          instrument: instrument
        )
      }
    }
  }
}
