import Foundation

// Earmark / category / investment / analysis / refresh handlers extracted
// from the main `AutomationService` body so it stays under SwiftLint's
// `type_body_length` threshold. All members are `@MainActor` via the
// containing class.
extension AutomationService {

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
      instrument: instrument,
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
