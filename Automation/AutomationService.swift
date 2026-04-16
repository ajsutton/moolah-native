import Foundation
import OSLog

private let logger = Logger(subsystem: "com.moolah.app", category: "AutomationService")

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

  /// Returns the net worth (current + investment totals) for the given profile.
  func getNetWorth(profileIdentifier: String) throws -> InstrumentAmount {
    let session = try resolveSession(for: profileIdentifier)
    return session.accountStore.netWorth
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
    name: String? = nil,
    isHidden: Bool? = nil
  ) async throws -> Account {
    let session = try resolveSession(for: profileIdentifier)
    guard var account = session.accountStore.accounts.by(id: accountId) else {
      throw AutomationError.accountNotFound(accountId.uuidString)
    }
    if let name { account.name = name }
    if let isHidden { account.isHidden = isHidden }
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

    // Determine if this is a transfer (2+ legs with different account IDs)
    let isTransfer = accountIds.count > 1
    if isTransfer {
      // All legs in a transfer use .expense type
      resolvedLegs = resolvedLegs.map { leg in
        var copy = leg
        copy.type = .expense
        return copy
      }
    }

    let transaction = Transaction(
      id: UUID(),
      date: date,
      payee: payee,
      notes: notes,
      recurPeriod: nil,
      recurEvery: nil,
      legs: resolvedLegs
    )

    guard let created = await session.transactionStore.create(transaction) else {
      throw AutomationError.operationFailed("Failed to create transaction")
    }
    return created
  }

  /// Lists transactions, optionally filtered by account name and/or scheduled status.
  func listTransactions(
    profileIdentifier: String,
    accountName: String? = nil,
    scheduled: Bool? = nil
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

  // MARK: - Earmark Operations

  /// Returns all earmarks for the given profile.
  func listEarmarks(profileIdentifier: String) throws -> [Earmark] {
    let session = try resolveSession(for: profileIdentifier)
    return Array(session.earmarkStore.earmarks)
  }

  /// Resolves an earmark by name (case-insensitive) within a profile.
  func resolveEarmark(named name: String, profileIdentifier: String) throws -> Earmark {
    let session = try resolveSession(for: profileIdentifier)
    let lowered = name.lowercased()
    guard
      let earmark = session.earmarkStore.earmarks.first(where: { $0.name.lowercased() == lowered })
    else {
      throw AutomationError.earmarkNotFound(name)
    }
    return earmark
  }

  /// Creates a new earmark in the given profile.
  func createEarmark(
    profileIdentifier: String,
    name: String,
    targetAmount: Decimal? = nil,
    savingsEndDate: Date? = nil
  ) async throws -> Earmark {
    let session = try resolveSession(for: profileIdentifier)
    let instrument = session.profile.instrument
    let earmark = Earmark(
      id: UUID(),
      name: name,
      isHidden: false,
      position: session.earmarkStore.earmarks.count,
      savingsGoal: targetAmount.map { InstrumentAmount(quantity: $0, instrument: instrument) },
      savingsStartDate: savingsEndDate != nil ? Date() : nil,
      savingsEndDate: savingsEndDate
    )

    guard let created = await session.earmarkStore.create(earmark) else {
      throw AutomationError.operationFailed("Failed to create earmark")
    }
    return created
  }

  /// Updates an existing earmark.
  func updateEarmark(
    profileIdentifier: String,
    earmarkId: UUID,
    name: String? = nil,
    targetAmount: Decimal? = nil,
    savingsEndDate: Date? = nil
  ) async throws -> Earmark {
    let session = try resolveSession(for: profileIdentifier)
    let instrument = session.profile.instrument
    guard var earmark = session.earmarkStore.earmarks.by(id: earmarkId) else {
      throw AutomationError.earmarkNotFound(earmarkId.uuidString)
    }
    if let name { earmark.name = name }
    if let targetAmount {
      earmark.savingsGoal = InstrumentAmount(quantity: targetAmount, instrument: instrument)
    }
    if let savingsEndDate {
      earmark.savingsEndDate = savingsEndDate
      if earmark.savingsStartDate == nil {
        earmark.savingsStartDate = Date()
      }
    }

    guard let updated = await session.earmarkStore.update(earmark) else {
      throw AutomationError.operationFailed("Failed to update earmark")
    }
    return updated
  }

  /// Hides an earmark by UUID (earmarks cannot be deleted, only hidden).
  func deleteEarmark(profileIdentifier: String, earmarkId: UUID) async throws {
    let session = try resolveSession(for: profileIdentifier)
    guard var earmark = session.earmarkStore.earmarks.by(id: earmarkId) else {
      throw AutomationError.earmarkNotFound(earmarkId.uuidString)
    }
    earmark.isHidden = true
    guard await session.earmarkStore.update(earmark) != nil else {
      throw AutomationError.operationFailed("Failed to hide earmark")
    }
  }

  // MARK: - Category Operations

  /// Returns all categories for the given profile.
  func listCategories(profileIdentifier: String) throws -> [Category] {
    let session = try resolveSession(for: profileIdentifier)
    return session.categoryStore.categories.flattenedByPath().map(\.category)
  }

  /// Resolves a category by name or path (case-insensitive) within a profile.
  /// Matches either the category name or the full path (e.g., "Food:Groceries").
  func resolveCategory(named name: String, profileIdentifier: String) throws -> Category {
    let session = try resolveSession(for: profileIdentifier)
    let lowered = name.lowercased()
    let entries = session.categoryStore.categories.flattenedByPath()

    // Try matching by path first, then by name
    if let entry = entries.first(where: { $0.path.lowercased() == lowered }) {
      return entry.category
    }
    if let entry = entries.first(where: { $0.category.name.lowercased() == lowered }) {
      return entry.category
    }

    throw AutomationError.categoryNotFound(name)
  }

  /// Creates a new category, optionally under a parent.
  func createCategory(
    profileIdentifier: String,
    name: String,
    parentName: String? = nil
  ) async throws -> Category {
    let parentId: UUID?
    if let parentName {
      parentId = try resolveCategory(named: parentName, profileIdentifier: profileIdentifier).id
    } else {
      parentId = nil
    }

    let session = try resolveSession(for: profileIdentifier)
    let category = Category(id: UUID(), name: name, parentId: parentId)

    guard let created = await session.categoryStore.create(category) else {
      throw AutomationError.operationFailed("Failed to create category")
    }
    return created
  }

  /// Deletes a category, optionally replacing it with another category.
  func deleteCategory(
    profileIdentifier: String,
    categoryId: UUID,
    replacementName: String? = nil
  ) async throws {
    let session = try resolveSession(for: profileIdentifier)

    let replacementId: UUID?
    if let replacementName {
      replacementId = try resolveCategory(
        named: replacementName, profileIdentifier: profileIdentifier
      ).id
    } else {
      replacementId = nil
    }

    let success = await session.categoryStore.delete(id: categoryId, withReplacement: replacementId)
    if !success {
      throw AutomationError.operationFailed("Failed to delete category")
    }
  }

  // MARK: - Investment Operations

  /// Sets the investment value for an account on a given date.
  func setInvestmentValue(
    profileIdentifier: String,
    accountName: String,
    date: Date,
    value: Decimal
  ) async throws {
    let session = try resolveSession(for: profileIdentifier)
    let account = try resolveAccount(named: accountName, profileIdentifier: profileIdentifier)

    guard account.type == .investment else {
      throw AutomationError.invalidParameter(
        "Account '\(accountName)' is not an investment account")
    }

    let instrument = session.profile.instrument
    let amount = InstrumentAmount(quantity: value, instrument: instrument)
    await session.investmentStore.setValue(accountId: account.id, date: date, value: amount)
  }

  /// Returns positions for a given investment account.
  func getPositions(profileIdentifier: String, accountName: String) async throws -> [Position] {
    let session = try resolveSession(for: profileIdentifier)
    let account = try resolveAccount(named: accountName, profileIdentifier: profileIdentifier)
    await session.investmentStore.loadPositions(accountId: account.id)
    return session.investmentStore.positions
  }

  // MARK: - Analysis Operations

  /// Loads analysis data (daily balances, expense breakdown, income/expense).
  func loadAnalysis(
    profileIdentifier: String,
    historyMonths: Int? = nil,
    forecastMonths: Int? = nil
  ) async throws -> AnalysisData {
    let session = try resolveSession(for: profileIdentifier)

    if let historyMonths {
      session.analysisStore.historyMonths = historyMonths
    }
    if let forecastMonths {
      session.analysisStore.forecastMonths = forecastMonths
    }

    await session.analysisStore.loadAll()

    if let error = session.analysisStore.error {
      throw AutomationError.operationFailed(
        "Failed to load analysis: \(error.localizedDescription)")
    }

    return AnalysisData(
      dailyBalances: session.analysisStore.dailyBalances,
      expenseBreakdown: session.analysisStore.expenseBreakdown,
      incomeAndExpense: session.analysisStore.incomeAndExpense
    )
  }

  // MARK: - Refresh

  /// Refreshes all stores for the given profile concurrently.
  func refresh(profileIdentifier: String) async throws {
    let session = try resolveSession(for: profileIdentifier)

    async let accountsLoad: Void = session.accountStore.load()
    async let categoriesLoad: Void = session.categoryStore.load()
    async let earmarksLoad: Void = session.earmarkStore.load()

    _ = await (accountsLoad, categoriesLoad, earmarksLoad)
  }
}
