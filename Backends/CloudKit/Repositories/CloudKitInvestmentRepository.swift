import Foundation
import SwiftData

final class CloudKitInvestmentRepository: InvestmentRepository, @unchecked Sendable {
  private let modelContainer: ModelContainer
  private let currency: Currency

  init(modelContainer: ModelContainer, currency: Currency) {
    self.modelContainer = modelContainer
    self.currency = currency
  }

  @MainActor
  private var context: ModelContext {
    modelContainer.mainContext
  }

  func fetchValues(accountId: UUID, page: Int, pageSize: Int) async throws -> InvestmentValuePage {
    let descriptor = FetchDescriptor<InvestmentValueRecord>(
      predicate: #Predicate { $0.accountId == accountId },
      sortBy: [SortDescriptor(\.date, order: .reverse)]
    )
    return try await MainActor.run {
      let allRecords = try context.fetch(descriptor)
      let offset = page * pageSize
      guard offset < allRecords.count else {
        return InvestmentValuePage(values: [], hasMore: false)
      }
      let end = min(offset + pageSize, allRecords.count)
      let pageValues = allRecords[offset..<end].map { $0.toDomain() }
      return InvestmentValuePage(values: Array(pageValues), hasMore: end < allRecords.count)
    }
  }

  func setValue(accountId: UUID, date: Date, value: MonetaryAmount) async throws {
    let descriptor = FetchDescriptor<InvestmentValueRecord>(
      predicate: #Predicate {
        $0.accountId == accountId && $0.date == date
      }
    )

    try await MainActor.run {
      if let existing = try context.fetch(descriptor).first {
        existing.value = value.cents
        existing.currencyCode = value.currency.code
      } else {
        let record = InvestmentValueRecord(
          accountId: accountId, date: date,
          value: value.cents, currencyCode: value.currency.code)
        context.insert(record)
      }
      try context.save()
    }
  }

  func removeValue(accountId: UUID, date: Date) async throws {
    let descriptor = FetchDescriptor<InvestmentValueRecord>(
      predicate: #Predicate {
        $0.accountId == accountId && $0.date == date
      }
    )

    try await MainActor.run {
      guard let record = try context.fetch(descriptor).first else {
        throw BackendError.notFound("Investment value not found")
      }
      context.delete(record)
      try context.save()
    }
  }

  func fetchDailyBalances(accountId: UUID) async throws -> [AccountDailyBalance] {
    let descriptor = FetchDescriptor<InvestmentValueRecord>(
      predicate: #Predicate { $0.accountId == accountId },
      sortBy: [SortDescriptor(\.date)]
    )
    return try await MainActor.run {
      let records = try context.fetch(descriptor)
      return records.map {
        AccountDailyBalance(
          date: $0.date,
          balance: MonetaryAmount(cents: $0.value, currency: Currency.from(code: $0.currencyCode))
        )
      }
    }
  }
}
