import Foundation
import SwiftData
import os

final class CloudKitEarmarkRepository: EarmarkRepository, @unchecked Sendable {
  private let modelContainer: ModelContainer
  private let currency: Currency
  var onRecordChanged: (UUID) -> Void = { _ in }
  var onRecordDeleted: (UUID) -> Void = { _ in }

  init(modelContainer: ModelContainer, currency: Currency) {
    self.modelContainer = modelContainer
    self.currency = currency
  }

  @MainActor
  private var context: ModelContext {
    modelContainer.mainContext
  }

  func fetchAll() async throws -> [Earmark] {
    let signpostID = OSSignpostID(log: Signposts.repository)
    os_signpost(
      .begin, log: Signposts.repository, name: "EarmarkRepo.fetchAll", signpostID: signpostID)
    defer {
      os_signpost(
        .end, log: Signposts.repository, name: "EarmarkRepo.fetchAll", signpostID: signpostID)
    }
    let descriptor = FetchDescriptor<EarmarkRecord>()
    return try await MainActor.run {
      let records = try context.fetch(descriptor)
      return try records.map { record in
        let (balance, saved, spent) = try computeEarmarkTotals(for: record.id)
        return record.toDomain(balance: balance, saved: saved, spent: spent)
      }.sorted()
    }
  }

  func create(_ earmark: Earmark) async throws -> Earmark {
    let signpostID = OSSignpostID(log: Signposts.repository)
    os_signpost(
      .begin, log: Signposts.repository, name: "EarmarkRepo.create", signpostID: signpostID)
    defer {
      os_signpost(
        .end, log: Signposts.repository, name: "EarmarkRepo.create", signpostID: signpostID)
    }
    let record = EarmarkRecord.from(earmark, currencyCode: currency.code)
    try await MainActor.run {
      context.insert(record)
      try context.save()
      onRecordChanged(earmark.id)
    }
    return earmark
  }

  func update(_ earmark: Earmark) async throws -> Earmark {
    let signpostID = OSSignpostID(log: Signposts.repository)
    os_signpost(
      .begin, log: Signposts.repository, name: "EarmarkRepo.update", signpostID: signpostID)
    defer {
      os_signpost(
        .end, log: Signposts.repository, name: "EarmarkRepo.update", signpostID: signpostID)
    }
    let earmarkId = earmark.id
    let descriptor = FetchDescriptor<EarmarkRecord>(
      predicate: #Predicate { $0.id == earmarkId }
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
      onRecordChanged(earmark.id)
    }
    return earmark
  }

  func fetchBudget(earmarkId: UUID) async throws -> [EarmarkBudgetItem] {
    let signpostID = OSSignpostID(log: Signposts.repository)
    os_signpost(
      .begin, log: Signposts.repository, name: "EarmarkRepo.fetchBudget", signpostID: signpostID)
    defer {
      os_signpost(
        .end, log: Signposts.repository, name: "EarmarkRepo.fetchBudget", signpostID: signpostID)
    }
    let descriptor = FetchDescriptor<EarmarkBudgetItemRecord>(
      predicate: #Predicate { $0.earmarkId == earmarkId }
    )
    return try await MainActor.run {
      let records = try context.fetch(descriptor)
      return records.map { $0.toDomain() }
    }
  }

  func setBudget(earmarkId: UUID, categoryId: UUID, amount: Int) async throws {
    let signpostID = OSSignpostID(log: Signposts.repository)
    os_signpost(
      .begin, log: Signposts.repository, name: "EarmarkRepo.setBudget", signpostID: signpostID)
    defer {
      os_signpost(
        .end, log: Signposts.repository, name: "EarmarkRepo.setBudget", signpostID: signpostID)
    }
    let earmarkDescriptor = FetchDescriptor<EarmarkRecord>(
      predicate: #Predicate { $0.id == earmarkId }
    )

    try await MainActor.run {
      guard try context.fetch(earmarkDescriptor).first != nil else {
        throw BackendError.serverError(404)
      }

      let budgetDescriptor = FetchDescriptor<EarmarkBudgetItemRecord>(
        predicate: #Predicate {
          $0.earmarkId == earmarkId && $0.categoryId == categoryId
        }
      )
      let existing = try context.fetch(budgetDescriptor).first

      if amount == 0 {
        if let existing {
          let deletedId = existing.id
          context.delete(existing)
          try context.save()
          onRecordDeleted(deletedId)
        }
      } else if let existing {
        existing.amount = amount
        existing.currencyCode = currency.code
        try context.save()
        onRecordChanged(existing.id)
      } else {
        let record = EarmarkBudgetItemRecord(
          earmarkId: earmarkId,
          categoryId: categoryId,
          amount: amount,
          currencyCode: currency.code
        )
        context.insert(record)
        try context.save()
        onRecordChanged(record.id)
      }
    }
  }

  @MainActor
  private func computeEarmarkTotals(for earmarkId: UUID) throws -> (
    balance: MonetaryAmount, saved: MonetaryAmount, spent: MonetaryAmount
  ) {
    let descriptor = FetchDescriptor<TransactionRecord>(
      predicate: #Predicate {
        $0.earmarkId == earmarkId && $0.recurPeriod == nil
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
