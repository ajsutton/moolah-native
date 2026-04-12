import Foundation
import SwiftData
import os

final class CloudKitAccountRepository: AccountRepository, @unchecked Sendable {
  private let modelContainer: ModelContainer
  private let instrument: Instrument
  var onRecordChanged: (UUID) -> Void = { _ in }
  var onRecordDeleted: (UUID) -> Void = { _ in }

  init(modelContainer: ModelContainer, instrument: Instrument) {
    self.modelContainer = modelContainer
    self.instrument = instrument
  }

  @MainActor
  private var context: ModelContext {
    modelContainer.mainContext
  }

  func fetchAll() async throws -> [Account] {
    let signpostID = OSSignpostID(log: Signposts.repository)
    os_signpost(
      .begin, log: Signposts.repository, name: "AccountRepo.fetchAll", signpostID: signpostID)
    defer {
      os_signpost(
        .end, log: Signposts.repository, name: "AccountRepo.fetchAll", signpostID: signpostID)
    }
    let descriptor = FetchDescriptor<AccountRecord>(
      sortBy: [SortDescriptor(\.position)]
    )
    return try await MainActor.run {
      let records = try context.fetch(descriptor)
      let balances = try computeAllBalances()

      return try records.map { record in
        let storageValue = balances[record.id] ?? 0
        let balance = InstrumentAmount(storageValue: storageValue, instrument: instrument)
        let investmentValue =
          record.type == AccountType.investment.rawValue
          ? try latestInvestmentValue(for: record.id)
          : nil
        return record.toDomain(balance: balance, investmentValue: investmentValue)
      }
    }
  }

  func create(_ account: Account) async throws -> Account {
    let signpostID = OSSignpostID(log: Signposts.repository)
    os_signpost(
      .begin, log: Signposts.repository, name: "AccountRepo.create", signpostID: signpostID)
    defer {
      os_signpost(
        .end, log: Signposts.repository, name: "AccountRepo.create", signpostID: signpostID)
    }
    guard !account.name.trimmingCharacters(in: .whitespaces).isEmpty else {
      throw BackendError.validationFailed("Account name cannot be empty")
    }

    let record = AccountRecord.from(account)
    try await MainActor.run {
      context.insert(record)

      // If account has an opening balance, create an opening balance transaction with a leg
      if !account.balance.isZero {
        let txnId = UUID()
        let txnRecord = TransactionRecord(
          id: txnId,
          date: Date()
        )
        context.insert(txnRecord)

        try ensureInstrument(account.balance.instrument)

        let legRecord = TransactionLegRecord(
          transactionId: txnId,
          accountId: account.id,
          instrumentId: account.balance.instrument.id,
          quantity: account.balance.storageValue,
          type: TransactionType.openingBalance.rawValue,
          sortOrder: 0
        )
        context.insert(legRecord)
        try context.save()
        onRecordChanged(account.id)
        onRecordChanged(txnRecord.id)
      } else {
        try context.save()
        onRecordChanged(account.id)
      }
    }

    return account
  }

  func update(_ account: Account) async throws -> Account {
    let signpostID = OSSignpostID(log: Signposts.repository)
    os_signpost(
      .begin, log: Signposts.repository, name: "AccountRepo.update", signpostID: signpostID)
    defer {
      os_signpost(
        .end, log: Signposts.repository, name: "AccountRepo.update", signpostID: signpostID)
    }
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
      try context.save()
      onRecordChanged(account.id)

      let balances = try computeAllBalances()
      let storageValue = balances[accountId] ?? 0
      let balance = InstrumentAmount(storageValue: storageValue, instrument: instrument)
      let investmentValue =
        record.type == AccountType.investment.rawValue
        ? try latestInvestmentValue(for: accountId)
        : nil
      return record.toDomain(balance: balance, investmentValue: investmentValue)
    }
  }

  func delete(id: UUID) async throws {
    let signpostID = OSSignpostID(log: Signposts.repository)
    os_signpost(
      .begin, log: Signposts.repository, name: "AccountRepo.delete", signpostID: signpostID)
    defer {
      os_signpost(
        .end, log: Signposts.repository, name: "AccountRepo.delete", signpostID: signpostID)
    }
    let descriptor = FetchDescriptor<AccountRecord>(
      predicate: #Predicate { $0.id == id }
    )

    try await MainActor.run {
      guard let record = try context.fetch(descriptor).first else {
        throw BackendError.notFound("Account not found")
      }

      let balances = try computeAllBalances()
      let storageValue = balances[id] ?? 0
      guard storageValue == 0 else {
        throw BackendError.validationFailed("Cannot delete account with non-zero balance")
      }

      // Soft delete
      record.isHidden = true
      try context.save()
      onRecordChanged(id)
    }
  }

  // MARK: - Balance Computation

  /// Compute all account balances in a single pass over leg records.
  /// Returns a dictionary of accountId -> storageValue (Int64).
  @MainActor
  private func computeAllBalances() throws -> [UUID: Int64] {
    // Get scheduled transaction IDs to exclude
    let scheduledDescriptor = FetchDescriptor<TransactionRecord>(
      predicate: #Predicate { $0.recurPeriod != nil }
    )
    let scheduledIds = Set(try context.fetch(scheduledDescriptor).map(\.id))

    // Fetch all legs and accumulate per account
    let legDescriptor = FetchDescriptor<TransactionLegRecord>()
    let allLegs = try context.fetch(legDescriptor)

    var balances: [UUID: Int64] = [:]
    for leg in allLegs {
      guard !scheduledIds.contains(leg.transactionId) else { continue }
      balances[leg.accountId, default: 0] += leg.quantity
    }
    return balances
  }

  // MARK: - Instrument Cache

  @MainActor private var instrumentCacheForAccount: [String: Instrument] = [:]

  @MainActor
  private func ensureInstrument(_ instrument: Instrument) throws {
    let iid = instrument.id
    let descriptor = FetchDescriptor<InstrumentRecord>(predicate: #Predicate { $0.id == iid })
    if try context.fetch(descriptor).isEmpty {
      context.insert(InstrumentRecord.from(instrument))
    }
    instrumentCacheForAccount[instrument.id] = instrument
  }

  @MainActor
  private func latestInvestmentValue(for accountId: UUID) throws -> InstrumentAmount? {
    var descriptor = FetchDescriptor<InvestmentValueRecord>(
      predicate: #Predicate { $0.accountId == accountId },
      sortBy: [SortDescriptor(\.date, order: .reverse)]
    )
    descriptor.fetchLimit = 1
    let records = try context.fetch(descriptor)
    return records.first?.toDomain().value
  }
}
