import Foundation
import SwiftData
import Testing

@testable import Moolah

// MARK: - Factory Helpers

// Shared across the `InvestmentRepository` contract test files. `strict_fileprivate`
// disallows `fileprivate`, and these are consumed from sibling files, so the smallest
// legal access level is `internal` (the default). They remain test-only because the
// file lives in the MoolahTests target.

/// Returns a stable accountId used across repos for seeded-data tests.
let sharedAccountId = UUID()

/// Helper to extract the account ID from a seeded CloudKit repo.
/// For loop-based tests where accountId was seeded separately.
func getAccountId(from repo: any InvestmentRepository) async -> UUID {
  // This is only called on repos built with makeCloudKitInvestmentRepository
  // which uses sharedAccountId — we return it directly.
  sharedAccountId
}

/// Builds a `CloudKitInvestmentRepository` with an in-memory SwiftData container.
/// Optionally seeds `InvestmentValueRecord`s for the given dates.
func makeCloudKitInvestmentRepository(
  dates: [Date] = [],
  accountId: UUID = sharedAccountId,
  quantity: Decimal = Decimal(1000),
  instrument: Instrument = .defaultTestInstrument
) throws -> CloudKitInvestmentRepository {
  let container = try TestModelContainer.create()
  let repo = CloudKitInvestmentRepository(
    modelContainer: container, instrument: instrument)

  if !dates.isEmpty {
    let context = ModelContext(container)
    for date in dates {
      let amount = InstrumentAmount(quantity: quantity, instrument: instrument)
      let record = InvestmentValueRecord(
        accountId: accountId,
        date: date,
        value: amount.storageValue,
        instrumentId: instrument.id
      )
      context.insert(record)
    }
    try context.save()
  }

  return repo
}

/// Builds a `CloudKitInvestmentRepository` and returns the underlying container so the
/// caller can seed transactions via `TestBackend.seed(transactions:in:)`.
func makeCloudKitInvestmentRepositoryWithContainer(
  instrument: Instrument = .defaultTestInstrument
) throws -> (CloudKitInvestmentRepository, ModelContainer) {
  let container = try TestModelContainer.create()
  let repo = CloudKitInvestmentRepository(
    modelContainer: container, instrument: instrument)
  return (repo, container)
}

/// Constructs a midnight `Date` for the given year/month/day, failing the test if the
/// calendar returns nil (shouldn't happen for valid components).
func makeContractTestDate(year: Int, month: Int, day: Int) throws -> Date {
  try #require(Calendar.current.date(from: DateComponents(year: year, month: month, day: day)))
}
