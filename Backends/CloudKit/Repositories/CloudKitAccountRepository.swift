import Foundation
import SwiftData

final class CloudKitAccountRepository: AccountRepository, @unchecked Sendable {
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

  func fetchAll() async throws -> [Account] {
    let descriptor = FetchDescriptor<AccountRecord>(
      sortBy: [SortDescriptor(\.position)]
    )
    return try await MainActor.run {
      let records = try context.fetch(descriptor)

      // If any record has a nil cached balance, recompute all balances in batch
      if records.contains(where: { $0.cachedBalance == nil }) {
        try recomputeAllBalances(records: records)
      }

      return try records.map { record in
        let balance = MonetaryAmount(cents: record.cachedBalance ?? 0, currency: currency)
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

    let record = AccountRecord.from(account, currencyCode: currency.code)
    try await MainActor.run {
      context.insert(record)

      // If account has an opening balance, create an opening balance transaction
      if account.balance.cents != 0 {
        let txn = TransactionRecord(
          type: TransactionType.openingBalance.rawValue,
          date: Date(),
          accountId: account.id,
          amount: account.balance.cents,
          currencyCode: currency.code
        )
        context.insert(txn)
        record.cachedBalance = account.balance.cents
      } else {
        record.cachedBalance = 0
      }

      try context.save()
    }

    return account
  }

  func update(_ account: Account) async throws -> Account {
    let accountId = account.id
    let descriptor = FetchDescriptor<AccountRecord>(
      predicate: #Predicate { $0.id == accountId }
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
    let descriptor = FetchDescriptor<AccountRecord>(
      predicate: #Predicate { $0.id == id }
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

  /// Batch-recompute all account balances in a single pass over transactions.
  /// This replaces N per-account queries with 1 query for all transactions.
  @MainActor
  private func recomputeAllBalances(records: [AccountRecord]) throws {
    let txnDescriptor = FetchDescriptor<TransactionRecord>(
      predicate: #Predicate {
        $0.recurPeriod == nil
      }
    )
    let transactions = try context.fetch(txnDescriptor)

    // Accumulate per-account balances in a single pass
    var balances: [UUID: Int] = [:]
    for record in records {
      balances[record.id] = 0
    }

    for txn in transactions {
      // Source account gets +amount
      if let accountId = txn.accountId {
        balances[accountId, default: 0] += txn.amount
      }
      // Destination account (transfers) gets -amount
      if let toAccountId = txn.toAccountId {
        balances[toAccountId, default: 0] -= txn.amount
      }
    }

    // Write cached balances to records
    for record in records {
      record.cachedBalance = balances[record.id] ?? 0
    }

    try context.save()
  }

  @MainActor
  private func computeBalance(for accountId: UUID) throws -> MonetaryAmount {
    // Sum transactions where this is the source account (non-scheduled only)
    let sourceDescriptor = FetchDescriptor<TransactionRecord>(
      predicate: #Predicate {
        $0.accountId == accountId && $0.recurPeriod == nil
      }
    )
    let sourceRecords = try context.fetch(sourceDescriptor)
    let sourceSum = sourceRecords.reduce(0) { $0 + $1.amount }

    // For transfers where this is the destination account
    let destDescriptor = FetchDescriptor<TransactionRecord>(
      predicate: #Predicate {
        $0.toAccountId == accountId && $0.recurPeriod == nil
      }
    )
    let destRecords = try context.fetch(destDescriptor)
    let destSum = destRecords.reduce(0) { $0 + $1.amount }

    // source account gets the amount, dest account gets the negative (transfer in)
    let balance = MonetaryAmount(cents: sourceSum - destSum, currency: currency)

    // Write through to cache
    let accountDescriptor = FetchDescriptor<AccountRecord>(
      predicate: #Predicate { $0.id == accountId }
    )
    if let record = try context.fetch(accountDescriptor).first {
      record.cachedBalance = balance.cents
    }

    return balance
  }

  @MainActor
  private func latestInvestmentValue(for accountId: UUID) throws -> MonetaryAmount? {
    var descriptor = FetchDescriptor<InvestmentValueRecord>(
      predicate: #Predicate { $0.accountId == accountId },
      sortBy: [SortDescriptor(\.date, order: .reverse)]
    )
    descriptor.fetchLimit = 1
    let records = try context.fetch(descriptor)
    return records.first?.toDomain().value
  }
}
