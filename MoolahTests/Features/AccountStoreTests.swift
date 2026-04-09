import Foundation
import Testing

@testable import Moolah

@Suite("AccountStore")
@MainActor
struct AccountStoreTests {
  @Test func testPopulatesFromRepository() async throws {
    let account = Account(
      name: "Checking", type: .bank,
      balance: MonetaryAmount(cents: 100000, currency: Currency.defaultTestCurrency))
    let repository = InMemoryAccountRepository(initialAccounts: [account])
    let store = AccountStore(repository: repository)

    await store.load()

    #expect(store.accounts.count == 1)
    #expect(store.accounts.first?.name == "Checking")
  }

  @Test func testSortingByPosition() async throws {
    let a1 = Account(
      name: "A1", type: .bank,
      balance: MonetaryAmount(cents: 10000, currency: Currency.defaultTestCurrency), position: 2)
    let a2 = Account(
      name: "A2", type: .asset,
      balance: MonetaryAmount(cents: 20000, currency: Currency.defaultTestCurrency), position: 1)
    let repository = InMemoryAccountRepository(initialAccounts: [a1, a2])
    let store = AccountStore(repository: repository)

    await store.load()

    #expect(store.accounts.count == 2)
    #expect(store.accounts[0].name == "A2")
    #expect(store.accounts[1].name == "A1")
  }

  @Test func testCalculatesTotals() async throws {
    let accounts = [
      Account(
        name: "Bank", type: .bank,
        balance: MonetaryAmount(cents: 100000, currency: Currency.defaultTestCurrency)),
      Account(
        name: "Asset", type: .asset,
        balance: MonetaryAmount(cents: 500000, currency: Currency.defaultTestCurrency)),
      Account(
        name: "Credit Card", type: .creditCard,
        balance: MonetaryAmount(cents: -50000, currency: Currency.defaultTestCurrency)),
      Account(
        name: "Investment", type: .investment,
        balance: MonetaryAmount(cents: 2_000_000, currency: Currency.defaultTestCurrency)),
      Account(
        name: "Hidden", type: .asset,
        balance: MonetaryAmount(cents: 100_000_000, currency: Currency.defaultTestCurrency),
        isHidden: true),
    ]
    let repository = InMemoryAccountRepository(initialAccounts: accounts)
    let store = AccountStore(repository: repository)

    await store.load()

    #expect(
      store.currentTotal == MonetaryAmount(cents: 550000, currency: Currency.defaultTestCurrency))  // 100000 + 500000 - 50000
    #expect(
      store.investmentTotal
        == MonetaryAmount(cents: 2_000_000, currency: Currency.defaultTestCurrency))
    #expect(
      store.netWorth == MonetaryAmount(cents: 2_550_000, currency: Currency.defaultTestCurrency))
  }

  @Test func testAvailableFunds() async throws {
    let accounts = [
      Account(
        name: "Checking", type: .bank,
        balance: MonetaryAmount(cents: 100000, currency: Currency.defaultTestCurrency)),  // 1000.00
      Account(
        name: "Savings", type: .asset,
        balance: MonetaryAmount(cents: 500000, currency: Currency.defaultTestCurrency)),  // 5000.00
      // Current Total = 6000.00
    ]
    let repository = InMemoryAccountRepository(initialAccounts: accounts)
    let store = AccountStore(repository: repository)

    await store.load()

    // Available Funds = Current Total (6000.00) = 3000.00
    #expect(
      store.availableFunds == MonetaryAmount(cents: 600000, currency: Currency.defaultTestCurrency))
  }

  // MARK: - applyTransactionDelta

  @Test func testCreateExpenseReducesAccountBalance() async throws {
    let acctId = UUID()
    let repository = InMemoryAccountRepository(initialAccounts: [
      Account(
        id: acctId, name: "Checking", type: .bank,
        balance: MonetaryAmount(cents: 100000, currency: Currency.defaultTestCurrency))
    ])
    let store = AccountStore(repository: repository)
    await store.load()

    let tx = Transaction(
      type: .expense, date: Date(), accountId: acctId,
      amount: MonetaryAmount(cents: -5000, currency: Currency.defaultTestCurrency),
      payee: "Coffee"
    )
    store.applyTransactionDelta(old: nil, new: tx)

    #expect(store.accounts.by(id: acctId)?.balance.cents == 95000)
  }

  @Test func testCreateIncomeIncreasesAccountBalance() async throws {
    let acctId = UUID()
    let repository = InMemoryAccountRepository(initialAccounts: [
      Account(
        id: acctId, name: "Checking", type: .bank,
        balance: MonetaryAmount(cents: 100000, currency: Currency.defaultTestCurrency))
    ])
    let store = AccountStore(repository: repository)
    await store.load()

    let tx = Transaction(
      type: .income, date: Date(), accountId: acctId,
      amount: MonetaryAmount(cents: 50000, currency: Currency.defaultTestCurrency),
      payee: "Salary"
    )
    store.applyTransactionDelta(old: nil, new: tx)

    #expect(store.accounts.by(id: acctId)?.balance.cents == 150000)
  }

  @Test func testDeleteRevertsAccountBalance() async throws {
    let acctId = UUID()
    let repository = InMemoryAccountRepository(initialAccounts: [
      Account(
        id: acctId, name: "Checking", type: .bank,
        balance: MonetaryAmount(cents: 95000, currency: Currency.defaultTestCurrency))
    ])
    let store = AccountStore(repository: repository)
    await store.load()

    let tx = Transaction(
      type: .expense, date: Date(), accountId: acctId,
      amount: MonetaryAmount(cents: -5000, currency: Currency.defaultTestCurrency),
      payee: "Coffee"
    )
    store.applyTransactionDelta(old: tx, new: nil)

    // Removing a -5000 expense should add 5000 back
    #expect(store.accounts.by(id: acctId)?.balance.cents == 100000)
  }

  @Test func testUpdateAdjustsAccountBalance() async throws {
    let acctId = UUID()
    let repository = InMemoryAccountRepository(initialAccounts: [
      Account(
        id: acctId, name: "Checking", type: .bank,
        balance: MonetaryAmount(cents: 95000, currency: Currency.defaultTestCurrency))
    ])
    let store = AccountStore(repository: repository)
    await store.load()

    let oldTx = Transaction(
      type: .expense, date: Date(), accountId: acctId,
      amount: MonetaryAmount(cents: -5000, currency: Currency.defaultTestCurrency),
      payee: "Coffee"
    )
    var newTx = oldTx
    newTx.amount = MonetaryAmount(cents: -7500, currency: Currency.defaultTestCurrency)

    store.applyTransactionDelta(old: oldTx, new: newTx)

    // Was 95000 (after -5000 expense). Remove old (-(-5000) = +5000 → 100000), apply new (-7500 → 92500)
    #expect(store.accounts.by(id: acctId)?.balance.cents == 92500)
  }

  @Test func testTransferUpdatesBothAccounts() async throws {
    let checkingId = UUID()
    let savingsId = UUID()
    let repository = InMemoryAccountRepository(initialAccounts: [
      Account(
        id: checkingId, name: "Checking", type: .bank,
        balance: MonetaryAmount(cents: 100000, currency: Currency.defaultTestCurrency)),
      Account(
        id: savingsId, name: "Savings", type: .bank,
        balance: MonetaryAmount(cents: 200000, currency: Currency.defaultTestCurrency)),
    ])
    let store = AccountStore(repository: repository)
    await store.load()

    // Transfer $100 from checking to savings (amount is -10000 from source perspective)
    let tx = Transaction(
      type: .transfer, date: Date(), accountId: checkingId, toAccountId: savingsId,
      amount: MonetaryAmount(cents: -10000, currency: Currency.defaultTestCurrency)
    )
    store.applyTransactionDelta(old: nil, new: tx)

    #expect(store.accounts.by(id: checkingId)?.balance.cents == 90000)
    #expect(store.accounts.by(id: savingsId)?.balance.cents == 210000)
  }

  @Test func testDeleteTransferRevertsBothAccounts() async throws {
    let checkingId = UUID()
    let savingsId = UUID()
    let repository = InMemoryAccountRepository(initialAccounts: [
      Account(
        id: checkingId, name: "Checking", type: .bank,
        balance: MonetaryAmount(cents: 90000, currency: Currency.defaultTestCurrency)),
      Account(
        id: savingsId, name: "Savings", type: .bank,
        balance: MonetaryAmount(cents: 210000, currency: Currency.defaultTestCurrency)),
    ])
    let store = AccountStore(repository: repository)
    await store.load()

    let tx = Transaction(
      type: .transfer, date: Date(), accountId: checkingId, toAccountId: savingsId,
      amount: MonetaryAmount(cents: -10000, currency: Currency.defaultTestCurrency)
    )
    store.applyTransactionDelta(old: tx, new: nil)

    #expect(store.accounts.by(id: checkingId)?.balance.cents == 100000)
    #expect(store.accounts.by(id: savingsId)?.balance.cents == 200000)
  }

  @Test func testTotalsUpdateAfterDelta() async throws {
    let checkingId = UUID()
    let repository = InMemoryAccountRepository(initialAccounts: [
      Account(
        id: checkingId, name: "Checking", type: .bank,
        balance: MonetaryAmount(cents: 100000, currency: Currency.defaultTestCurrency))
    ])
    let store = AccountStore(repository: repository)
    await store.load()

    #expect(store.currentTotal.cents == 100000)
    #expect(store.netWorth.cents == 100000)

    let tx = Transaction(
      type: .expense, date: Date(), accountId: checkingId,
      amount: MonetaryAmount(cents: -5000, currency: Currency.defaultTestCurrency),
      payee: "Coffee"
    )
    store.applyTransactionDelta(old: nil, new: tx)

    #expect(store.currentTotal.cents == 95000)
    #expect(store.netWorth.cents == 95000)
  }

  // MARK: - Show Hidden

  @Test("currentAccounts excludes hidden accounts by default")
  func hiddenAccountsExcluded() async {
    let visible = Account(
      name: "Visible", type: .bank,
      balance: MonetaryAmount(cents: 100000, currency: Currency.defaultTestCurrency))
    let hidden = Account(
      name: "Hidden", type: .bank,
      balance: MonetaryAmount(cents: 50000, currency: Currency.defaultTestCurrency),
      isHidden: true)
    let repository = InMemoryAccountRepository(initialAccounts: [visible, hidden])
    let store = AccountStore(repository: repository)

    await store.load()

    #expect(store.currentAccounts.count == 1)
    #expect(store.currentAccounts[0].name == "Visible")
  }

  @Test("currentAccounts includes hidden accounts when showHidden is true")
  func hiddenAccountsIncluded() async {
    let visible = Account(
      name: "Visible", type: .bank,
      balance: MonetaryAmount(cents: 100000, currency: Currency.defaultTestCurrency))
    let hidden = Account(
      name: "Hidden", type: .bank,
      balance: MonetaryAmount(cents: 50000, currency: Currency.defaultTestCurrency),
      isHidden: true)
    let repository = InMemoryAccountRepository(initialAccounts: [visible, hidden])
    let store = AccountStore(repository: repository)

    await store.load()
    store.showHidden = true

    #expect(store.currentAccounts.count == 2)
  }

  @Test("investmentAccounts respects showHidden flag")
  func hiddenInvestmentAccounts() async {
    let visible = Account(
      name: "Visible", type: .investment,
      balance: MonetaryAmount(cents: 100000, currency: Currency.defaultTestCurrency))
    let hidden = Account(
      name: "Hidden", type: .investment,
      balance: MonetaryAmount(cents: 50000, currency: Currency.defaultTestCurrency),
      isHidden: true)
    let repository = InMemoryAccountRepository(initialAccounts: [visible, hidden])
    let store = AccountStore(repository: repository)

    await store.load()

    #expect(store.investmentAccounts.count == 1)
    store.showHidden = true
    #expect(store.investmentAccounts.count == 2)
  }
}
