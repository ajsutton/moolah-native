import Foundation

actor InMemoryAccountRepository: AccountRepository {
  private var accounts: [UUID: Account]

  init(initialAccounts: [Account] = []) {
    self.accounts = Dictionary(uniqueKeysWithValues: initialAccounts.map { ($0.id, $0) })
  }

  func fetchAll() async throws -> [Account] {
    // Return all accounts including hidden (matches server behavior).
    // UI-level filtering of hidden accounts is done by AccountStore.
    // Sort: investment accounts last, then by position, then by name (matches server).
    return Array(accounts.values)
      .sorted { a, b in
        if a.type.isCurrent != b.type.isCurrent { return a.type.isCurrent }
        if a.position != b.position { return a.position < b.position }
        return a.name < b.name
      }
  }

  func create(_ account: Account) async throws -> Account {
    // Validation
    guard !account.name.trimmingCharacters(in: .whitespaces).isEmpty else {
      throw BackendError.validationFailed("Account name cannot be empty")
    }

    // Check for duplicate ID (shouldn't happen, but defensive)
    guard accounts[account.id] == nil else {
      throw BackendError.validationFailed("Account ID already exists")
    }

    // Store account (opening balance is already in the account.balance field)
    accounts[account.id] = account

    return account
  }

  func update(_ account: Account) async throws -> Account {
    guard let existing = accounts[account.id] else {
      throw BackendError.notFound("Account not found")
    }

    // Validation
    guard !account.name.trimmingCharacters(in: .whitespaces).isEmpty else {
      throw BackendError.validationFailed("Account name cannot be empty")
    }

    // Preserve balance (server-computed, not updated by client)
    var updated = account
    updated.balance = existing.balance

    accounts[account.id] = updated
    return updated
  }

  func delete(id: UUID) async throws {
    guard let account = accounts[id] else {
      throw BackendError.notFound("Account not found")
    }

    // Validate balance is zero
    guard account.balance.cents == 0 else {
      throw BackendError.validationFailed("Cannot delete account with non-zero balance")
    }

    // Soft delete
    var updated = account
    updated.isHidden = true
    accounts[id] = updated
  }

  // For test setup
  func setAccounts(_ accounts: [Account]) {
    self.accounts = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
  }
}
