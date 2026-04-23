import Foundation
import OSLog

private let logger = Logger(subsystem: "com.moolah.app", category: "AutomationService")

/// Tri-state change to an account's `isHidden` flag used by
/// `AutomationService.updateAccount(...)`. Replaces a `Bool?` so an
/// "unchanged" intent can't be confused with "set to false" at call sites
/// and keeps SwiftLint's `discouraged_optional_boolean` rule satisfied.
enum AccountHiddenChange: Sendable {
  case unchanged
  case setTo(Bool)
}

/// Describes a partial update to an account. Fields left `nil` / `.unchanged`
/// are preserved; set fields are applied.
struct AccountChanges: Sendable {
  var name: String?
  var hidden: AccountHiddenChange

  init(name: String? = nil, hidden: AccountHiddenChange = .unchanged) {
    self.name = name
    self.hidden = hidden
  }
}

@MainActor
final class AutomationService {
  let sessionManager: SessionManager

  init(sessionManager: SessionManager) {
    self.sessionManager = sessionManager
  }

  /// Resolves a profile session by name (case-insensitive) or UUID string.
  func resolveSession(for identifier: String) throws -> ProfileSession {
    if let session = sessionManager.session(named: identifier) { return session }
    if let uuid = UUID(uuidString: identifier),
      let session = sessionManager.session(forID: uuid)
    {
      return session
    }
    throw AutomationError.profileNotFound(identifier)
  }

  /// Returns all currently open profiles.
  func listOpenProfiles() -> [Profile] {
    sessionManager.openProfiles.map(\.profile)
  }

  // MARK: - Account Operations

  /// Returns all accounts for the given profile.
  func listAccounts(profileIdentifier: String) throws -> [Account] {
    let session = try resolveSession(for: profileIdentifier)
    return Array(session.accountStore.accounts)
  }

  /// Resolves an account by name (case-insensitive) within a profile.
  func resolveAccount(named name: String, profileIdentifier: String) throws -> Account {
    let session = try resolveSession(for: profileIdentifier)
    let lowered = name.lowercased()
    guard
      let account = session.accountStore.accounts.first(where: { $0.name.lowercased() == lowered })
    else {
      throw AutomationError.accountNotFound(name)
    }
    return account
  }

  /// Resolves an account by UUID within a profile.
  func resolveAccount(id: UUID, profileIdentifier: String) throws -> Account {
    let session = try resolveSession(for: profileIdentifier)
    guard let account = session.accountStore.accounts.by(id: id) else {
      throw AutomationError.accountNotFound(id.uuidString)
    }
    return account
  }

  /// Returns the net worth (current + investment totals) for the given profile,
  /// converted into the profile's instrument.
  func getNetWorth(profileIdentifier: String) async throws -> InstrumentAmount {
    let session = try resolveSession(for: profileIdentifier)
    do {
      return try await session.accountStore.computeConvertedNetWorth(
        in: session.profile.instrument)
    } catch {
      throw AutomationError.operationFailed(
        "Failed to compute net worth: \(error.localizedDescription)")
    }
  }

  /// Creates a new account in the given profile.
  func createAccount(
    profileIdentifier: String,
    name: String,
    type: AccountType,
    isHidden: Bool = false
  ) async throws -> Account {
    let session = try resolveSession(for: profileIdentifier)
    let instrument = session.profile.instrument
    let account = Account(
      id: UUID(),
      name: name,
      type: type,
      instrument: instrument,
      position: session.accountStore.accounts.count,
      isHidden: isHidden
    )
    do {
      return try await session.accountStore.create(account)
    } catch {
      throw AutomationError.operationFailed(
        "Failed to create account: \(error.localizedDescription)")
    }
  }

  /// Updates an existing account's name and/or hidden status.
  func updateAccount(
    profileIdentifier: String,
    accountId: UUID,
    changes: AccountChanges
  ) async throws -> Account {
    let session = try resolveSession(for: profileIdentifier)
    guard var account = session.accountStore.accounts.by(id: accountId) else {
      throw AutomationError.accountNotFound(accountId.uuidString)
    }
    if let name = changes.name { account.name = name }
    if case .setTo(let hidden) = changes.hidden { account.isHidden = hidden }
    do {
      return try await session.accountStore.update(account)
    } catch {
      throw AutomationError.operationFailed(
        "Failed to update account: \(error.localizedDescription)")
    }
  }

  /// Deletes an account by UUID.
  func deleteAccount(profileIdentifier: String, accountId: UUID) async throws {
    let session = try resolveSession(for: profileIdentifier)
    do {
      try await session.accountStore.delete(id: accountId)
    } catch {
      throw AutomationError.operationFailed(
        "Failed to delete account: \(error.localizedDescription)")
    }
  }

  // MARK: - Transaction Operations

  /// Describes a single leg of a transaction for creation.
  struct LegSpec: Sendable {
    let accountName: String
    let amount: Decimal
    let categoryName: String?
    let earmarkName: String?
  }

  /// Creates a transaction with the specified legs.
  func createTransaction(
    profileIdentifier: String,
    payee: String,
    date: Date,
    legs: [LegSpec],
    notes: String? = nil
  ) async throws -> Transaction {
    let session = try resolveSession(for: profileIdentifier)
    let instrument = session.profile.instrument

    let resolution = try resolveLegs(
      legs, profileIdentifier: profileIdentifier, instrument: instrument)
    let finalLegs = normaliseTransferLegs(resolution.legs, accountIds: resolution.accountIds)

    let transaction = Transaction(
      id: UUID(),
      date: date,
      payee: payee,
      notes: notes,
      recurPeriod: nil,
      recurEvery: nil,
      legs: finalLegs
    )

    guard let created = await session.transactionStore.create(transaction) else {
      throw AutomationError.operationFailed("Failed to create transaction")
    }
    return created
  }

  private func resolveLegs(
    _ legs: [LegSpec], profileIdentifier: String, instrument: Instrument
  ) throws -> (legs: [TransactionLeg], accountIds: Set<UUID>) {
    var resolvedLegs: [TransactionLeg] = []
    var accountIds = Set<UUID>()
    for spec in legs {
      let account = try resolveAccount(
        named: spec.accountName, profileIdentifier: profileIdentifier)
      accountIds.insert(account.id)

      let categoryId: UUID? =
        if let categoryName = spec.categoryName {
          try resolveCategory(named: categoryName, profileIdentifier: profileIdentifier).id
        } else {
          nil
        }

      let earmarkId: UUID? =
        if let earmarkName = spec.earmarkName {
          try resolveEarmark(named: earmarkName, profileIdentifier: profileIdentifier).id
        } else {
          nil
        }

      let legType: TransactionType = spec.amount >= 0 ? .income : .expense
      resolvedLegs.append(
        TransactionLeg(
          accountId: account.id,
          instrument: instrument,
          quantity: spec.amount,
          type: legType,
          categoryId: categoryId,
          earmarkId: earmarkId
        ))
    }
    return (resolvedLegs, accountIds)
  }

  private func normaliseTransferLegs(
    _ legs: [TransactionLeg], accountIds: Set<UUID>
  ) -> [TransactionLeg] {
    // Transfers (2+ legs with different accounts) use .expense type on every leg.
    guard accountIds.count > 1 else { return legs }
    return legs.map { leg in
      var copy = leg
      copy.type = .expense
      return copy
    }
  }

  /// Lists transactions, optionally filtered by account name and/or scheduled status.
  func listTransactions(
    profileIdentifier: String,
    accountName: String? = nil,
    scheduled: ScheduledFilter = .all
  ) async throws -> [Transaction] {
    let session = try resolveSession(for: profileIdentifier)

    var filter = TransactionFilter()
    if let accountName {
      let account = try resolveAccount(named: accountName, profileIdentifier: profileIdentifier)
      filter.accountId = account.id
    }
    filter.scheduled = scheduled

    await session.transactionStore.load(filter: filter)
    return session.transactionStore.transactions.map(\.transaction)
  }

  /// Updates an existing transaction's payee, date, or notes.
  func updateTransaction(
    profileIdentifier: String,
    transactionId: UUID,
    payee: String? = nil,
    date: Date? = nil,
    notes: String? = nil
  ) async throws -> Transaction {
    let session = try resolveSession(for: profileIdentifier)

    // Find the transaction in the store
    guard
      let entry = session.transactionStore.transactions.first(where: {
        $0.transaction.id == transactionId
      })
    else {
      throw AutomationError.transactionNotFound(transactionId.uuidString)
    }

    var transaction = entry.transaction
    if let payee { transaction.payee = payee }
    if let date { transaction.date = date }
    if let notes { transaction.notes = notes }

    await session.transactionStore.update(transaction)

    // Return the updated version from the store
    guard
      let updated = session.transactionStore.transactions.first(where: {
        $0.transaction.id == transactionId
      })
    else {
      throw AutomationError.operationFailed("Transaction update failed")
    }
    return updated.transaction
  }

  /// Deletes a transaction by UUID.
  func deleteTransaction(profileIdentifier: String, transactionId: UUID) async throws {
    let session = try resolveSession(for: profileIdentifier)
    await session.transactionStore.delete(id: transactionId)
  }

  /// Pays a scheduled transaction (creates a non-scheduled copy with today's date).
  func payScheduledTransaction(
    profileIdentifier: String,
    transactionId: UUID
  ) async throws -> TransactionStore.PayResult {
    let session = try resolveSession(for: profileIdentifier)

    guard
      let entry = session.transactionStore.transactions.first(where: {
        $0.transaction.id == transactionId
      })
    else {
      throw AutomationError.transactionNotFound(transactionId.uuidString)
    }

    return await session.transactionStore.payScheduledTransaction(entry.transaction)
  }

}
