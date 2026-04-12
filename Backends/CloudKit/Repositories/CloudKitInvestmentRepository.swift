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
    var descriptor = FetchDescriptor<InvestmentValueRecord>(
      predicate: #Predicate { $0.accountId == accountId },
      sortBy: [SortDescriptor(\.date, order: .reverse)]
    )
    descriptor.fetchOffset = page * pageSize
    descriptor.fetchLimit = pageSize

    let countDescriptor = FetchDescriptor<InvestmentValueRecord>(
      predicate: #Predicate { $0.accountId == accountId }
    )

    return try await MainActor.run {
      let records = try context.fetch(descriptor)
      let totalCount = try context.fetchCount(countDescriptor)
      let pageValues = records.map { $0.toDomain() }
      let nextOffset = (page + 1) * pageSize
      return InvestmentValuePage(values: pageValues, hasMore: nextOffset < totalCount)
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
