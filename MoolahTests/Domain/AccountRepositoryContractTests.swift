import Testing

@testable import Moolah

@Suite("AccountRepository Contract")
struct AccountRepositoryContractTests {

  // MARK: - CREATE TESTS

  @Test("InMemoryAccountRepository - creates account with opening balance")
  func testCreatesAccount() async throws {
    let repository = InMemoryAccountRepository()

    let newAccount = Account(
      name: "Savings",
      type: .bank,
      balance: MonetaryAmount(cents: 100000, currency: .defaultCurrency)
    )

    let created = try await repository.create(newAccount)

    #expect(created.id == newAccount.id)
    #expect(created.name == "Savings")
    #expect(created.balance.cents == 100000)

    let all = try await repository.fetchAll()
    #expect(all.count == 1)
  }

  @Test("InMemoryAccountRepository - rejects empty name")
  func testRejectsEmptyName() async throws {
    let repository = InMemoryAccountRepository()

    let invalidAccount = Account(
      name: "   ",  // Whitespace only
      type: .bank,
      balance: .zero
    )

    await #expect(throws: BackendError.self) {
      try await repository.create(invalidAccount)
    }
  }

  @Test("InMemoryAccountRepository - allows negative balance")
  func testAllowsNegativeBalance() async throws {
    let repository = InMemoryAccountRepository()

    let creditCard = Account(
      name: "Credit Card",
      type: .creditCard,
      balance: MonetaryAmount(cents: -50000, currency: .defaultCurrency)
    )

    let created = try await repository.create(creditCard)
    #expect(created.balance.cents == -50000)
  }

  // MARK: - UPDATE TESTS

  @Test("InMemoryAccountRepository - updates account name and type")
  func testUpdatesAccount() async throws {
    let repository = InMemoryAccountRepository(initialAccounts: [
      Account(id: UUID(), name: "Checking", type: .bank, balance: .zero)
    ])

    let accounts = try await repository.fetchAll()
    var toUpdate = accounts[0]
    toUpdate.name = "Business Checking"
    toUpdate.type = .asset

    let updated = try await repository.update(toUpdate)

    #expect(updated.name == "Business Checking")
    #expect(updated.type == .asset)
  }

  @Test("InMemoryAccountRepository - preserves balance on update")
  func testPreservesBalance() async throws {
    let repository = InMemoryAccountRepository(initialAccounts: [
      Account(
        id: UUID(),
        name: "Savings",
        type: .bank,
        balance: MonetaryAmount(cents: 100000, currency: .defaultCurrency)
      )
    ])

    let accounts = try await repository.fetchAll()
    var toUpdate = accounts[0]
    toUpdate.name = "Updated Savings"
    toUpdate.balance = MonetaryAmount(cents: 999999, currency: .defaultCurrency)  // Try to change

    let updated = try await repository.update(toUpdate)

    // Balance should be unchanged (server-authoritative)
    #expect(updated.balance.cents == 100000)
  }

  @Test("InMemoryAccountRepository - throws on update non-existent")
  func testThrowsOnUpdateNonExistent() async throws {
    let repository = InMemoryAccountRepository()

    let nonExistent = Account(name: "DoesNotExist", type: .bank)

    await #expect(throws: BackendError.self) {
      try await repository.update(nonExistent)
    }
  }

  // MARK: - DELETE TESTS

  @Test("InMemoryAccountRepository - soft deletes account with zero balance")
  func testDeletesAccountWithZeroBalance() async throws {
    let repository = InMemoryAccountRepository(initialAccounts: [
      Account(id: UUID(), name: "Old Account", type: .bank, balance: .zero)
    ])

    let accounts = try await repository.fetchAll()
    let toDelete = accounts[0]

    try await repository.delete(id: toDelete.id)

    let remaining = try await repository.fetchAll()
    // Account should be hidden (filtered out)
    #expect(!remaining.contains { $0.id == toDelete.id })
  }

  @Test("InMemoryAccountRepository - rejects delete with non-zero balance")
  func testRejectsDeleteWithBalance() async throws {
    let repository = InMemoryAccountRepository(initialAccounts: [
      Account(
        id: UUID(),
        name: "Active Account",
        type: .bank,
        balance: MonetaryAmount(cents: 100000, currency: .defaultCurrency)
      )
    ])

    let accounts = try await repository.fetchAll()
    let toDelete = accounts[0]

    await #expect(throws: BackendError.self) {
      try await repository.delete(id: toDelete.id)
    }
  }

  // MARK: - REORDERING TESTS

  @Test("InMemoryAccountRepository - updates positions")
  func testUpdatesPositions() async throws {
    let account1 = Account(id: UUID(), name: "First", type: .bank, position: 0)
    let account2 = Account(id: UUID(), name: "Second", type: .bank, position: 1)
    let account3 = Account(id: UUID(), name: "Third", type: .bank, position: 2)

    let repository = InMemoryAccountRepository(initialAccounts: [
      account1, account2, account3,
    ])

    // Reorder: move "Third" to first position
    var updated3 = account3
    updated3.position = 0

    var updated1 = account1
    updated1.position = 1

    var updated2 = account2
    updated2.position = 2

    _ = try await repository.update(updated3)
    _ = try await repository.update(updated1)
    _ = try await repository.update(updated2)

    let all = try await repository.fetchAll()
    let sorted = all.sorted()  // Uses position for Comparable

    #expect(sorted[0].name == "Third")
    #expect(sorted[1].name == "First")
    #expect(sorted[2].name == "Second")
  }
}
