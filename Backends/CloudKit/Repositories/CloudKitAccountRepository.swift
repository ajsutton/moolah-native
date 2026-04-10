import Foundation
import SwiftData

final class CloudKitAccountRepository: AccountRepository, @unchecked Sendable {
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

  func fetchAll() async throws -> [Account] {
    let profileId = self.profileId
    let descriptor = FetchDescriptor<AccountRecord>(
      predicate: #Predicate { $0.profileId == profileId },
      sortBy: [SortDescriptor(\.position)]
    )
    return try await MainActor.run {
      let records = try context.fetch(descriptor)
      return try records.map { record in
        let balance = try computeBalance(for: record.id)
        let investmentValue =
          record.type == AccountType.investment.rawValue
          ? try latestInvestmentValue(for: record.id)
          : nil
        return record.toDomain(balance: balance, investmentValue: investmentValue)
      }
    }
  }

  func create(_ account: Account) async throws -> Account {
    guard !account.name.trimmingCharacters(in: .whitespaces).isEmpty else {
      throw BackendError.validationFailed("Account name cannot be empty")
    }

    let record = AccountRecord.from(account, profileId: profileId, currencyCode: currency.code)
    try await MainActor.run {
      context.insert(record)

      // If account has an opening balance, create an opening balance transaction
      if account.balance.cents != 0 {
        let txn = TransactionRecord(
          profileId: profileId,
          type: TransactionType.openingBalance.rawValue,
          date: Date(),
          accountId: account.id,
          amount: account.balance.cents,
          currencyCode: currency.code
        )
        context.insert(txn)
      }

      try context.save()
    }

    return account
  }

  func update(_ account: Account) async throws -> Account {
    let accountId = account.id
    let profileId = self.profileId
    let descriptor = FetchDescriptor<AccountRecord>(
      predicate: #Predicate { $0.id == accountId && $0.profileId == profileId }
    )

    guard !account.name.trimmingCharacters(in: .whitespaces).isEmpty else {
      throw BackendError.validationFailed("Account name cannot be empty")
    }

    return try await MainActor.run {
      guard let record = try context.fetch(descriptor).first else {
        throw BackendError.notFound("Account not found")
      }
      record.name = account.name
      record.type = account.type.rawValue
      record.position = account.position
      record.isHidden = account.isHidden
      // Balance is NOT updated — it's computed from transactions
      try context.save()

      let balance = try computeBalance(for: accountId)
      let investmentValue =
        record.type == AccountType.investment.rawValue
        ? try latestInvestmentValue(for: accountId)
        : nil
      return record.toDomain(balance: balance, investmentValue: investmentValue)
    }
  }

  func delete(id: UUID) async throws {
    let profileId = self.profileId
    let descriptor = FetchDescriptor<AccountRecord>(
      predicate: #Predicate { $0.id == id && $0.profileId == profileId }
    )

    try await MainActor.run {
      guard let record = try context.fetch(descriptor).first else {
        throw BackendError.notFound("Account not found")
      }

      let balance = try computeBalance(for: id)
      guard balance.cents == 0 else {
        throw BackendError.validationFailed("Cannot delete account with non-zero balance")
      }

      // Soft delete
      record.isHidden = true
      try context.save()
    }
  }

  // MARK: - Balance Computation

  @MainActor
  private func computeBalance(for accountId: UUID) throws -> MonetaryAmount {
    let profileId = self.profileId
    // Sum transactions where this is the source account (non-scheduled only)
    let sourceDescriptor = FetchDescriptor<TransactionRecord>(
      predicate: #Predicate {
        $0.profileId == profileId && $0.accountId == accountId && $0.recurPeriod == nil
      }
    )
    let sourceRecords = try context.fetch(sourceDescriptor)
    let sourceSum = sourceRecords.reduce(0) { $0 + $1.amount }

    // For transfers where this is the destination account
    let destDescriptor = FetchDescriptor<TransactionRecord>(
      predicate: #Predicate {
        $0.profileId == profileId && $0.toAccountId == accountId && $0.recurPeriod == nil
      }
    )
    let destRecords = try context.fetch(destDescriptor)
    let destSum = destRecords.reduce(0) { $0 + $1.amount }

    // source account gets the amount, dest account gets the negative (transfer in)
    return MonetaryAmount(cents: sourceSum - destSum, currency: currency)
  }

  @MainActor
  private func latestInvestmentValue(for accountId: UUID) throws -> MonetaryAmount? {
    let profileId = self.profileId
    var descriptor = FetchDescriptor<InvestmentValueRecord>(
      predicate: #Predicate { $0.profileId == profileId && $0.accountId == accountId },
      sortBy: [SortDescriptor(\.date, order: .reverse)]
    )
    descriptor.fetchLimit = 1
    let records = try context.fetch(descriptor)
    return records.first?.toDomain().value
  }
}
