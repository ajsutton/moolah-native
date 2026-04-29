import Foundation
import GRDB
import Testing

@testable import Moolah

// MARK: - Factory Helpers

// Shared across the `InvestmentRepository` contract test files. `strict_fileprivate`
// disallows `fileprivate`, and these are consumed from sibling files, so the smallest
// legal access level is `internal` (the default). They remain test-only because the
// file lives in the MoolahTests target.

/// Returns a stable accountId used across repos for seeded-data tests.
let sharedAccountId = UUID()

/// Helper to extract the account ID from a seeded repo. For loop-based tests
/// where `accountId` was seeded separately.
func getAccountId(from repo: any InvestmentRepository) async -> UUID {
  // This is only called on repos built with makeCloudKitInvestmentRepository
  // which uses sharedAccountId — we return it directly.
  sharedAccountId
}

/// Builds an `InvestmentRepository` over an in-memory GRDB queue. Optionally
/// seeds `InvestmentValueRow`s for the given dates.
func makeCloudKitInvestmentRepository(
  dates: [Date] = [],
  accountId: UUID = sharedAccountId,
  quantity: Decimal = Decimal(1000),
  instrument: Instrument = .defaultTestInstrument
) throws -> any InvestmentRepository {
  let pair = try TestBackend.create(instrument: instrument)
  if !dates.isEmpty {
    let amount = InstrumentAmount(quantity: quantity, instrument: instrument)
    let values = dates.map { InvestmentValue(date: $0, value: amount) }
    TestBackend.seed(
      investmentValues: [accountId: values], in: pair.database, instrument: instrument)
  }
  return pair.backend.investments
}

/// Builds an `InvestmentRepository` and returns the underlying GRDB queue so the
/// caller can seed transactions via `TestBackend.seed(transactions:in:)`.
func makeCloudKitInvestmentRepositoryWithContainer(
  instrument: Instrument = .defaultTestInstrument
) throws -> (any InvestmentRepository, DatabaseQueue) {
  let pair = try TestBackend.create(instrument: instrument)
  return (pair.backend.investments, pair.database)
}

/// Constructs a midnight `Date` for the given year/month/day, failing the test if the
/// calendar returns nil (shouldn't happen for valid components).
func makeContractTestDate(year: Int, month: Int, day: Int) throws -> Date {
  try #require(Calendar.current.date(from: DateComponents(year: year, month: month, day: day)))
}
