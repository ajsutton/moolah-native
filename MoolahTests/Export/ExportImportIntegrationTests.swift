import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("Export/Import File Integration")
@MainActor
struct ExportImportIntegrationTests {

  private let instrument = Instrument.defaultTestInstrument

  /// Seeds a CloudKitBackend with realistic data for testing.
  private func makeSeededBackend() async throws -> CloudKitBackend {
    let (backend, _) = try TestBackend.create(instrument: instrument)

    let checking = try await backend.accounts.create(
      Account(
        name: "Checking", type: .bank,
        instrument: instrument
      ),
      openingBalance: InstrumentAmount(quantity: Decimal(string: "500.00")!, instrument: instrument)
    )

    let food = try await backend.categories.create(Category(name: "Food"))
    _ = try await backend.categories.create(Category(name: "Transport"))

    let holiday = try await backend.earmarks.create(
      Earmark(name: "Holiday", instrument: instrument)
    )
    let budgetAmount = InstrumentAmount(quantity: Decimal(string: "30.00")!, instrument: instrument)
    try await backend.earmarks.setBudget(
      earmarkId: holiday.id, categoryId: food.id, amount: budgetAmount)

    _ = try await backend.transactions.create(
      Transaction(
        date: Date(),
        payee: "Employer",
        legs: [
          TransactionLeg(
            accountId: checking.id, instrument: instrument,
            quantity: Decimal(string: "500.00")!, type: .income
          )
        ]
      )
    )

    _ = try await backend.transactions.create(
      Transaction(
        date: Date(),
        payee: "Cafe",
        legs: [
          TransactionLeg(
            accountId: checking.id, instrument: instrument,
            quantity: Decimal(string: "-15.00")!, type: .expense,
            categoryId: food.id, earmarkId: holiday.id
          )
        ]
      )
    )

    return backend
  }

  private func makeTempFileURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("moolah-test-\(UUID().uuidString).json")
  }

  @Test("export to JSON file and verify contents")
  func exportToFileAndVerify() async throws {
    let backend = try await makeSeededBackend()
    let tempURL = makeTempFileURL()
    defer { try? FileManager.default.removeItem(at: tempURL) }

    let profile = Profile(
      label: "Test Profile",
      backendType: .cloudKit,
      currencyCode: instrument.id,
      financialYearStartMonth: 7
    )

    let coordinator = MigrationCoordinator()
    try await coordinator.exportToFile(
      url: tempURL,
      backend: backend,
      profile: profile
    )

    // Verify file exists and is valid JSON
    let data = try Data(contentsOf: tempURL)
    let decoded = try JSONDecoder.exportDecoder.decode(ExportedData.self, from: data)

    #expect(decoded.profileLabel == "Test Profile")
    #expect(decoded.currencyCode == instrument.id)
    #expect(decoded.financialYearStartMonth == 7)
    #expect(decoded.accounts.count == 1)
    #expect(decoded.categories.count == 2)
    #expect(decoded.earmarks.count == 1)
    // 3 transactions: opening balance + income + expense
    #expect(decoded.transactions.count == 3)
    #expect(decoded.earmarkBudgets[decoded.earmarks.first!.id]?.count == 1)

    // Verify coordinator returned to idle state
    if case .idle = coordinator.state {
      // expected
    } else {
      Issue.record("Expected idle state, got \(coordinator.state)")
    }
  }

  @Test("import from JSON file into fresh container")
  func importFromFileRoundTrip() async throws {
    let backend = try await makeSeededBackend()
    let tempURL = makeTempFileURL()
    defer { try? FileManager.default.removeItem(at: tempURL) }

    // Export to file
    let profile = Profile(
      label: "Test Profile",
      backendType: .cloudKit,
      currencyCode: instrument.id,
      financialYearStartMonth: 7
    )

    let coordinator = MigrationCoordinator()
    try await coordinator.exportToFile(
      url: tempURL,
      backend: backend,
      profile: profile
    )

    // Import into fresh container
    let freshContainer = try TestModelContainer.create()
    let result = try await coordinator.importFromFile(
      url: tempURL,
      modelContainer: freshContainer
    )

    #expect(result.accountCount == 1)
    #expect(result.categoryCount == 2)
    #expect(result.earmarkCount == 1)
    // 3 transactions: opening balance + income + expense
    #expect(result.transactionCount == 3)
    #expect(result.budgetItemCount == 1)

    // Verify data is readable through CloudKit repositories
    let cloudBackend = CloudKitBackend(
      modelContainer: freshContainer,
      instrument: instrument,
      profileLabel: "Test Profile",
      conversionService: FixedConversionService()
    )

    let accounts = try await cloudBackend.accounts.fetchAll()
    #expect(accounts.count == 1)
    #expect(accounts.first?.name == "Checking")

    let categories = try await cloudBackend.categories.fetchAll()
    #expect(categories.count == 2)

    let earmarks = try await cloudBackend.earmarks.fetchAll()
    #expect(earmarks.count == 1)
    #expect(earmarks.first?.name == "Holiday")

    let budgetItems = try await cloudBackend.earmarks.fetchBudget(earmarkId: earmarks.first!.id)
    #expect(budgetItems.count == 1)
    #expect(budgetItems.first?.amount.quantity == Decimal(string: "30.00")!)

    let txnPage = try await cloudBackend.transactions.fetch(
      filter: TransactionFilter(), page: 0, pageSize: 100
    )
    // 3 transactions: opening balance + income + expense
    #expect(txnPage.transactions.count == 3)

    // Verify coordinator returned to idle state
    if case .idle = coordinator.state {
      // expected
    } else {
      Issue.record("Expected idle state, got \(coordinator.state)")
    }
  }

  @Test("importFromFile rejects unsupported version")
  func rejectsUnsupportedVersion() async throws {
    let exported = ExportedData(
      version: 99,
      exportedAt: Date(),
      profileLabel: "Test",
      currencyCode: "AUD",
      financialYearStartMonth: 1,
      accounts: [],
      categories: [],
      earmarks: [],
      earmarkBudgets: [:],
      transactions: [],
      investmentValues: [:]
    )
    let tempURL = FileManager.default.temporaryDirectory.appending(
      path: "\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: tempURL) }
    let data = try JSONEncoder.exportEncoder.encode(exported)
    try data.write(to: tempURL)

    let container = try TestModelContainer.create()
    let coordinator = MigrationCoordinator()

    await #expect(throws: MigrationError.self) {
      _ = try await coordinator.importFromFile(url: tempURL, modelContainer: container)
    }
  }

  @Test("importFromFile rejects nonexistent file")
  func rejectsNonexistentFile() async throws {
    let fakeURL = FileManager.default.temporaryDirectory.appending(
      path: "nonexistent-\(UUID().uuidString).json")
    let container = try TestModelContainer.create()
    let coordinator = MigrationCoordinator()

    await #expect(throws: MigrationError.self) {
      _ = try await coordinator.importFromFile(url: fakeURL, modelContainer: container)
    }
  }

  @Test("round-trip preserves fiat, stock, and crypto instruments across accounts, legs, earmarks")
  func multiCurrencyRoundTrip() async throws {
    let aud = Instrument.AUD
    let usd = Instrument.USD
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)

    let (backend, _) = try TestBackend.create(instrument: aud)

    let audAccount = try await backend.accounts.create(
      Account(name: "Checking AUD", type: .bank, instrument: aud),
      openingBalance: InstrumentAmount(quantity: Decimal(string: "1000.00")!, instrument: aud)
    )
    let usdAccount = try await backend.accounts.create(
      Account(name: "USD Travel", type: .bank, instrument: usd),
      openingBalance: InstrumentAmount(quantity: Decimal(string: "200.00")!, instrument: usd)
    )
    let stockAccount = try await backend.accounts.create(
      Account(name: "Brokerage", type: .investment, instrument: bhp),
      openingBalance: InstrumentAmount(quantity: Decimal(string: "10")!, instrument: bhp)
    )
    let cryptoAccount = try await backend.accounts.create(
      Account(name: "Crypto Wallet", type: .asset, instrument: eth),
      openingBalance: InstrumentAmount(quantity: Decimal(string: "0.5")!, instrument: eth)
    )

    let food = try await backend.categories.create(Category(name: "Food"))

    let usdEarmark = try await backend.earmarks.create(
      Earmark(
        name: "US Trip", instrument: usd,
        savingsGoal: InstrumentAmount(quantity: Decimal(string: "500.00")!, instrument: usd)
      )
    )
    try await backend.earmarks.setBudget(
      earmarkId: usdEarmark.id,
      categoryId: food.id,
      amount: InstrumentAmount(quantity: Decimal(string: "50.00")!, instrument: usd)
    )

    // Expense in USD, tagged to the USD earmark
    _ = try await backend.transactions.create(
      Transaction(
        date: Date(),
        payee: "NYC coffee",
        legs: [
          TransactionLeg(
            accountId: usdAccount.id, instrument: usd,
            quantity: Decimal(string: "-4.50")!, type: .expense,
            categoryId: food.id, earmarkId: usdEarmark.id
          )
        ]
      )
    )

    // Cross-instrument investment transfer (AUD -> BHP.AX)
    _ = try await backend.transactions.create(
      Transaction(
        date: Date(),
        payee: "Stock purchase",
        legs: [
          TransactionLeg(
            accountId: audAccount.id, instrument: aud,
            quantity: Decimal(string: "-500.00")!, type: .transfer
          ),
          TransactionLeg(
            accountId: stockAccount.id, instrument: bhp,
            quantity: Decimal(string: "5")!, type: .transfer
          ),
        ]
      )
    )

    // Crypto income
    _ = try await backend.transactions.create(
      Transaction(
        date: Date(),
        payee: "Staking reward",
        legs: [
          TransactionLeg(
            accountId: cryptoAccount.id, instrument: eth,
            quantity: Decimal(string: "0.05")!, type: .income
          )
        ]
      )
    )

    // Export via coordinator to a temporary JSON file
    let tempURL = makeTempFileURL()
    defer { try? FileManager.default.removeItem(at: tempURL) }

    let profile = Profile(
      label: "Multi-Currency Profile",
      backendType: .cloudKit,
      currencyCode: aud.id,
      financialYearStartMonth: 7
    )
    let coordinator = MigrationCoordinator()
    try await coordinator.exportToFile(url: tempURL, backend: backend, profile: profile)

    // Serialized JSON must list all four instruments for the importer to rehydrate them
    let exportedJSON = try Data(contentsOf: tempURL)
    let decoded = try JSONDecoder.exportDecoder.decode(ExportedData.self, from: exportedJSON)
    let exportedInstrumentIds = Set(decoded.instruments.map(\.id))
    #expect(exportedInstrumentIds == [aud.id, usd.id, bhp.id, eth.id])

    // Import into a fresh container and fetch everything back
    let freshContainer = try TestModelContainer.create()
    _ = try await coordinator.importFromFile(url: tempURL, modelContainer: freshContainer)

    let freshBackend = CloudKitBackend(
      modelContainer: freshContainer,
      instrument: aud,
      profileLabel: profile.label,
      conversionService: FixedConversionService()
    )

    // Accounts: each should come back on its original instrument, with its primary position
    let accounts = try await freshBackend.accounts.fetchAll()
    let accountById = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })

    let fetchedAud = try #require(accountById[audAccount.id])
    #expect(fetchedAud.instrument == aud)
    #expect(fetchedAud.positions.contains { $0.instrument == aud })

    let fetchedUsd = try #require(accountById[usdAccount.id])
    #expect(fetchedUsd.instrument == usd)
    #expect(fetchedUsd.positions.contains { $0.instrument == usd })

    let fetchedStock = try #require(accountById[stockAccount.id])
    #expect(fetchedStock.instrument == bhp)
    let bhpPosition = fetchedStock.positions.first { $0.instrument == bhp }
    #expect(bhpPosition?.instrument.kind == .stock)
    #expect(bhpPosition?.instrument.exchange == "ASX")
    #expect(bhpPosition?.instrument.ticker == "BHP.AX")

    let fetchedCrypto = try #require(accountById[cryptoAccount.id])
    #expect(fetchedCrypto.instrument == eth)
    let ethPosition = fetchedCrypto.positions.first { $0.instrument == eth }
    #expect(ethPosition?.instrument.kind == .cryptoToken)
    #expect(ethPosition?.instrument.chainId == 1)
    #expect(ethPosition?.instrument.decimals == 18)

    // Earmarks: USD earmark must stay on USD, not collapse to profile AUD
    let earmarks = try await freshBackend.earmarks.fetchAll()
    let fetchedEarmark = try #require(earmarks.first { $0.id == usdEarmark.id })
    #expect(fetchedEarmark.instrument == usd)
    #expect(fetchedEarmark.savingsGoal?.instrument == usd)

    let budgetItems = try await freshBackend.earmarks.fetchBudget(earmarkId: usdEarmark.id)
    #expect(budgetItems.first?.amount.instrument == usd)

    // Transaction legs: each leg must retain its own instrument (fiat, stock, or crypto)
    let txnPage = try await freshBackend.transactions.fetch(
      filter: TransactionFilter(), page: 0, pageSize: 100)
    let legInstruments = Set(txnPage.transactions.flatMap { $0.legs.map(\.instrument) })
    #expect(legInstruments == [aud, usd, bhp, eth])

    let stockLeg = txnPage.transactions
      .flatMap(\.legs)
      .first { $0.instrument.kind == .stock }
    #expect(stockLeg?.instrument.ticker == "BHP.AX")

    let cryptoLeg = txnPage.transactions
      .flatMap(\.legs)
      .first { $0.instrument.kind == .cryptoToken }
    #expect(cryptoLeg?.instrument.chainId == 1)
    #expect(cryptoLeg?.instrument.decimals == 18)
  }
}
