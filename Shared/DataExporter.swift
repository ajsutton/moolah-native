import Foundation

/// Exports all data from repository protocols (works with any BackendProvider).
actor DataExporter {
  private let backend: any BackendProvider

  enum ExportProgress: Sendable {
    case downloading(step: String)
    case downloadComplete(ExportedData)
    case failed(Error)
  }

  init(backend: any BackendProvider) {
    self.backend = backend
  }

  func export(
    profileLabel: String,
    currencyCode: String,
    financialYearStartMonth: Int,
    progress: @escaping @Sendable (ExportProgress) -> Void
  ) async throws -> ExportedData {
    // 1. Accounts
    progress(.downloading(step: "accounts"))
    let accounts: [Account]
    do {
      accounts = try await backend.accounts.fetchAll()
    } catch {
      throw MigrationError.exportFailed(step: "accounts", underlying: error)
    }

    // 2. Categories
    progress(.downloading(step: "categories"))
    let categories: [Category]
    do {
      categories = try await backend.categories.fetchAll()
    } catch {
      throw MigrationError.exportFailed(step: "categories", underlying: error)
    }

    // 3. Earmarks + budgets
    progress(.downloading(step: "earmarks"))
    let earmarks: [Earmark]
    var budgets: [UUID: [EarmarkBudgetItem]] = [:]
    do {
      earmarks = try await backend.earmarks.fetchAll()
      for earmark in earmarks {
        budgets[earmark.id] = try await backend.earmarks.fetchBudget(earmarkId: earmark.id)
      }
    } catch {
      throw MigrationError.exportFailed(step: "earmarks", underlying: error)
    }

    // 4. Transactions (paginated)
    progress(.downloading(step: "transactions"))
    let transactions: [Transaction]
    do {
      transactions = try await fetchAllTransactions()
    } catch {
      throw MigrationError.exportFailed(step: "transactions", underlying: error)
    }

    // 5. Investment values (per investment account)
    progress(.downloading(step: "investment values"))
    let investmentAccounts = accounts.filter { $0.type == .investment }
    var investmentValues: [UUID: [InvestmentValue]] = [:]
    do {
      for account in investmentAccounts {
        investmentValues[account.id] = try await fetchAllInvestmentValues(accountId: account.id)
      }
    } catch {
      throw MigrationError.exportFailed(step: "investment values", underlying: error)
    }

    let data = ExportedData(
      version: 1,
      exportedAt: Date(),
      profileLabel: profileLabel,
      currencyCode: currencyCode,
      financialYearStartMonth: financialYearStartMonth,
      accounts: accounts,
      categories: categories,
      earmarks: earmarks,
      earmarkBudgets: budgets,
      transactions: transactions,
      investmentValues: investmentValues
    )
    progress(.downloadComplete(data))
    return data
  }

  private func fetchAllTransactions() async throws -> [Transaction] {
    var allTransactions: [Transaction] = []
    var page = 0
    let pageSize = 200

    // Fetch all non-scheduled transactions
    while true {
      let result = try await backend.transactions.fetch(
        filter: TransactionFilter(),
        page: page,
        pageSize: pageSize
      )
      allTransactions.append(contentsOf: result.transactions)

      if result.transactions.count < pageSize {
        break
      }
      page += 1
    }

    // Also fetch scheduled transactions explicitly
    var scheduledPage = 0
    while true {
      let result = try await backend.transactions.fetch(
        filter: TransactionFilter(scheduled: true),
        page: scheduledPage,
        pageSize: pageSize
      )

      let existingIds = Set(allTransactions.map(\.id))
      let newTransactions = result.transactions.filter { !existingIds.contains($0.id) }
      allTransactions.append(contentsOf: newTransactions)

      if result.transactions.count < pageSize {
        break
      }
      scheduledPage += 1
    }

    return allTransactions
  }

  private func fetchAllInvestmentValues(accountId: UUID) async throws -> [InvestmentValue] {
    var allValues: [InvestmentValue] = []
    var page = 0
    let pageSize = 200

    while true {
      let result = try await backend.investments.fetchValues(
        accountId: accountId,
        page: page,
        pageSize: pageSize
      )
      allValues.append(contentsOf: result.values)

      if result.values.count < pageSize {
        break
      }
      page += 1
    }

    return allValues
  }
}
