import Foundation
import Testing

@testable import Moolah

@Suite("AccountStore")
@MainActor
struct AccountStoreTests {
  @Test func testPopulatesFromRepository() async throws {
    let account = Account(name: "Checking", type: .bank, balance: 100000)
    let repository = InMemoryAccountRepository(initialAccounts: [account])
    let store = AccountStore(repository: repository)

    await store.load()

    #expect(store.accounts.count == 1)
    #expect(store.accounts.first?.name == "Checking")
  }

  @Test func testSortingByPosition() async throws {
    let a1 = Account(name: "A1", type: .bank, balance: 10000, position: 2)
    let a2 = Account(name: "A2", type: .asset, balance: 20000, position: 1)
    let repository = InMemoryAccountRepository(initialAccounts: [a1, a2])
    let store = AccountStore(repository: repository)

    await store.load()

    #expect(store.accounts.count == 2)
    #expect(store.accounts[0].name == "A2")
    #expect(store.accounts[1].name == "A1")
  }

  @Test func testCalculatesTotals() async throws {
    let accounts = [
      Account(name: "Bank", type: .bank, balance: 100000),
      Account(name: "Asset", type: .asset, balance: 500000),
      Account(name: "Credit Card", type: .creditCard, balance: -50000),
      Account(name: "Investment", type: .investment, balance: 2_000_000),
      Account(name: "Hidden", type: .asset, balance: 100_000_000, isHidden: true),
    ]
    let repository = InMemoryAccountRepository(initialAccounts: accounts)
    let store = AccountStore(repository: repository)

    await store.load()

    #expect(store.currentTotal == 550000)  // 100000 + 500000 - 50000
    #expect(store.investmentTotal == 2_000_000)
    #expect(store.netWorth == 2_550_000)
  }

  @Test func testAvailableFunds() async throws {
    let accounts = [
      Account(name: "Checking", type: .bank, balance: 100000),  // 1000.00
      Account(name: "Savings", type: .asset, balance: 500000),  // 5000.00
      // Current Total = 6000.00
    ]
    let repository = InMemoryAccountRepository(initialAccounts: accounts)
    let store = AccountStore(repository: repository)

    await store.load()

    // Available Funds = Current Total (6000.00) = 3000.00
    #expect(store.availableFunds == 600000)
  }
}
