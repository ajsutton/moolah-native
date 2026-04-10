import Foundation
import SwiftData

final class CloudKitEarmarkRepository: EarmarkRepository, @unchecked Sendable {
  private let modelContainer: ModelContainer
  private let profileId: UUID
  private let currency: Currency

  init(modelContainer: ModelContainer, profileId: UUID, currency: Currency) {
    self.modelContainer = modelContainer
    self.profileId = profileId
    self.currency = currency
  }

  @MainActor
  private var context: ModelContext {
    modelContainer.mainContext
  }

  func fetchAll() async throws -> [Earmark] {
    let profileId = self.profileId
    let descriptor = FetchDescriptor<EarmarkRecord>(
      predicate: #Predicate { $0.profileId == profileId }
    )
    return try await MainActor.run {
      let records = try context.fetch(descriptor)
      return try records.map { record in
        let (balance, saved, spent) = try computeEarmarkTotals(for: record.id)
        return record.toDomain(balance: balance, saved: saved, spent: spent)
      }.sorted()
    }
  }

  func create(_ earmark: Earmark) async throws -> Earmark {
    let record = EarmarkRecord.from(earmark, profileId: profileId, currencyCode: currency.code)
    try await MainActor.run {
      context.insert(record)
      try context.save()
    }
    return earmark
  }

  func update(_ earmark: Earmark) async throws -> Earmark {
    let earmarkId = earmark.id
    let profileId = self.profileId
    let descriptor = FetchDescriptor<EarmarkRecord>(
      predicate: #Predicate { $0.id == earmarkId && $0.profileId == profileId }
    )

    try await MainActor.run {
      guard let record = try context.fetch(descriptor).first else {
        throw BackendError.serverError(404)
      }
      record.name = earmark.name
      record.position = earmark.position
      record.isHidden = earmark.isHidden
      record.savingsTarget = earmark.savingsGoal?.cents
      record.savingsStartDate = earmark.savingsStartDate
      record.savingsEndDate = earmark.savingsEndDate
      try context.save()
    }
    return earmark
  }

  func fetchBudget(earmarkId: UUID) async throws -> [EarmarkBudgetItem] {
    let profileId = self.profileId
    let descriptor = FetchDescriptor<EarmarkBudgetItemRecord>(
      predicate: #Predicate { $0.earmarkId == earmarkId && $0.profileId == profileId }
    )
    return try await MainActor.run {
      let records = try context.fetch(descriptor)
      return records.map { $0.toDomain() }
    }
  }

  func setBudget(earmarkId: UUID, categoryId: UUID, amount: Int) async throws {
    let profileId = self.profileId
    let earmarkDescriptor = FetchDescriptor<EarmarkRecord>(
      predicate: #Predicate { $0.id == earmarkId && $0.profileId == profileId }
    )

    try await MainActor.run {
      guard try context.fetch(earmarkDescriptor).first != nil else {
        throw BackendError.serverError(404)
      }

      let budgetDescriptor = FetchDescriptor<EarmarkBudgetItemRecord>(
        predicate: #Predicate {
          $0.earmarkId == earmarkId && $0.categoryId == categoryId && $0.profileId == profileId
        }
      )
      let existing = try context.fetch(budgetDescriptor).first

      if amount == 0 {
        if let existing { context.delete(existing) }
      } else if let existing {
        existing.amount = amount
        existing.currencyCode = currency.code
      } else {
        let record = EarmarkBudgetItemRecord(
          profileId: profileId,
          earmarkId: earmarkId,
          categoryId: categoryId,
          amount: amount,
          currencyCode: currency.code
        )
        context.insert(record)
      }
      try context.save()
    }
  }

  @MainActor
  private func computeEarmarkTotals(for earmarkId: UUID) throws -> (
    balance: MonetaryAmount, saved: MonetaryAmount, spent: MonetaryAmount
  ) {
    let profileId = self.profileId
    let descriptor = FetchDescriptor<TransactionRecord>(
      predicate: #Predicate {
        $0.profileId == profileId && $0.earmarkId == earmarkId && $0.recurPeriod == nil
      }
    )
    let records = try context.fetch(descriptor)

    let zero = MonetaryAmount(cents: 0, currency: currency)
    var balance = zero
    var saved = zero
    var spent = zero

    for record in records {
      let amount = MonetaryAmount(cents: record.amount, currency: currency)
      balance += amount
      if record.amount > 0 {
        saved += amount
      } else if record.amount < 0 {
        spent += MonetaryAmount(cents: abs(record.amount), currency: currency)
      }
    }

    return (balance, saved, spent)
  }
}
