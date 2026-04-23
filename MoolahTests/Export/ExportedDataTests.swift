import Foundation
import Testing

@testable import Moolah

@Suite("ExportedData")
struct ExportedDataTests {

  private let instrument = Instrument.defaultTestInstrument

  @Test("JSON round-trip preserves all fields")
  func jsonRoundTrip() throws {
    let accountId = UUID()
    let categoryId = UUID()
    let earmarkId = UUID()
    let exportDate = Date(timeIntervalSince1970: 1_700_000_000)

    let original = Self.makeSingleCurrencyFixture(
      accountId: accountId,
      categoryId: categoryId,
      earmarkId: earmarkId,
      exportedAt: exportDate,
      instrument: instrument)

    let data = try JSONEncoder.exportEncoder.encode(original)
    let decoded = try JSONDecoder.exportDecoder.decode(ExportedData.self, from: data)

    #expect(decoded.version == original.version)
    #expect(decoded.exportedAt == original.exportedAt)
    #expect(decoded.profileLabel == original.profileLabel)
    #expect(decoded.currencyCode == original.currencyCode)
    #expect(decoded.financialYearStartMonth == original.financialYearStartMonth)
    #expect(decoded.accounts.count == original.accounts.count)
    #expect(decoded.accounts.first?.id == accountId)
    #expect(decoded.accounts.first?.name == "Checking")
    #expect(decoded.categories.count == original.categories.count)
    #expect(decoded.categories.first?.id == categoryId)
    #expect(decoded.earmarks.count == original.earmarks.count)
    #expect(decoded.earmarks.first?.id == earmarkId)
    #expect(decoded.earmarkBudgets[earmarkId]?.count == 1)
    #expect(decoded.transactions.count == original.transactions.count)
    #expect(decoded.investmentValues.isEmpty)
  }

  private static func makeSingleCurrencyFixture(
    accountId: UUID,
    categoryId: UUID,
    earmarkId: UUID,
    exportedAt: Date,
    instrument: Instrument
  ) -> ExportedData {
    ExportedData(
      version: 1,
      exportedAt: exportedAt,
      profileLabel: "My Profile",
      currencyCode: "AUD",
      financialYearStartMonth: 7,
      accounts: [
        Account(
          id: accountId, name: "Checking", type: .bank,
          instrument: instrument
        )
      ],
      categories: [
        Category(id: categoryId, name: "Food")
      ],
      earmarks: [
        Earmark(
          id: earmarkId, name: "Holiday",
          instrument: instrument
        )
      ],
      earmarkBudgets: [
        earmarkId: [
          EarmarkBudgetItem(
            categoryId: categoryId,
            amount: InstrumentAmount(quantity: Decimal(string: "10.00")!, instrument: instrument)
          )
        ]
      ],
      transactions: [
        Transaction(
          date: Date(),
          payee: "Employer",
          legs: [
            TransactionLeg(
              accountId: accountId, instrument: instrument,
              quantity: Decimal(string: "50.00")!, type: .income
            )
          ]
        )
      ],
      investmentValues: [:]
    )
  }

  @Test("version field is present in JSON output")
  func versionFieldInJSON() throws {
    let exported = ExportedData(
      version: 1,
      exportedAt: Date(),
      profileLabel: "Test",
      currencyCode: "USD",
      financialYearStartMonth: 1,
      accounts: [],
      categories: [],
      earmarks: [],
      earmarkBudgets: [:],
      transactions: [],
      investmentValues: [:]
    )

    let data = try JSONEncoder.exportEncoder.encode(exported)
    let object = try JSONSerialization.jsonObject(with: data)
    let json = try #require(object as? [String: Any])

    #expect(json["version"] as? Int == 1)
    #expect(json["profileLabel"] as? String == "Test")
    #expect(json["currencyCode"] as? String == "USD")
    #expect(json["financialYearStartMonth"] as? Int == 1)
  }

  @Test("default metadata values for backward compatibility")
  func defaultMetadataValues() {
    let exported = ExportedData(
      accounts: [],
      categories: [],
      earmarks: [],
      earmarkBudgets: [:],
      transactions: [],
      investmentValues: [:]
    )

    #expect(exported.version == 1)
    #expect(exported.profileLabel.isEmpty)
    #expect(exported.currencyCode.isEmpty)
    #expect(exported.financialYearStartMonth == 1)
  }

  @Test("JSON round-trip preserves mixed-currency instruments on accounts, legs, and earmarks")
  func multiCurrencyRoundTrip() throws {
    let ids = MultiCurrencyFixtureIds()
    let original = Self.makeMultiCurrencyFixture(ids: ids)

    let data = try JSONEncoder.exportEncoder.encode(original)
    let decoded = try JSONDecoder.exportDecoder.decode(ExportedData.self, from: data)

    let aud = Instrument.AUD
    let usd = Instrument.USD
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)

    // Instruments list preserved (all four kinds: two fiat, stock, crypto)
    let decodedInstrumentsById = Dictionary(
      uniqueKeysWithValues: decoded.instruments.map { ($0.id, $0) })
    #expect(decoded.instruments.count == 4)
    #expect(decodedInstrumentsById[aud.id] == aud)
    #expect(decodedInstrumentsById[usd.id] == usd)
    #expect(decodedInstrumentsById[bhp.id] == bhp)
    #expect(decodedInstrumentsById[eth.id] == eth)

    // Accounts keep their instruments (fiat, stock, and crypto)
    let decodedAccountsById = Dictionary(uniqueKeysWithValues: decoded.accounts.map { ($0.id, $0) })
    #expect(decodedAccountsById[ids.audAccountId]?.instrument == aud)
    #expect(decodedAccountsById[ids.usdAccountId]?.instrument == usd)
    #expect(decodedAccountsById[ids.investmentAccountId]?.instrument == bhp)
    #expect(decodedAccountsById[ids.cryptoEarmarkAccountId]?.instrument == eth)

    // Earmark and its savings goal stay on the foreign fiat
    let decodedEarmark = decoded.earmarks.first { $0.id == ids.earmarkId }
    #expect(decodedEarmark?.instrument == usd)
    #expect(decodedEarmark?.savingsGoal?.instrument == usd)

    // Budget item stays on the earmark's instrument
    let decodedBudget = decoded.earmarkBudgets[ids.earmarkId]?.first
    #expect(decodedBudget?.amount.instrument == usd)

    // Legs carry through their full kind-specific metadata
    let legInstruments = decoded.transactions.flatMap { $0.legs.map(\.instrument) }
    #expect(Set(legInstruments) == Set([aud, usd, bhp, eth]))

    let stockLeg = decoded.transactions
      .flatMap { $0.legs }
      .first { $0.instrument.kind == .stock }
    #expect(stockLeg?.instrument.ticker == "BHP.AX")
    #expect(stockLeg?.instrument.exchange == "ASX")

    let cryptoLeg = decoded.transactions
      .flatMap { $0.legs }
      .first { $0.instrument.kind == .cryptoToken }
    #expect(cryptoLeg?.instrument.chainId == 1)
    #expect(cryptoLeg?.instrument.ticker == "ETH")
    #expect(cryptoLeg?.instrument.decimals == 18)

    // Investment values keep their instrument
    let decodedStockValues = decoded.investmentValues[ids.investmentAccountId]
    #expect(decodedStockValues?.first?.value.instrument == bhp)
    let decodedCryptoValues = decoded.investmentValues[ids.cryptoEarmarkAccountId]
    #expect(decodedCryptoValues?.first?.value.instrument == eth)
  }

  private struct MultiCurrencyFixtureIds {
    let audAccountId = UUID()
    let usdAccountId = UUID()
    let investmentAccountId = UUID()
    let cryptoEarmarkAccountId = UUID()
    let earmarkId = UUID()
    let foodCategoryId = UUID()
  }

  private static func makeMultiCurrencyFixture(ids: MultiCurrencyFixtureIds) -> ExportedData {
    let aud = Instrument.AUD
    let usd = Instrument.USD
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)

    return ExportedData(
      version: 1,
      exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
      profileLabel: "Multi-currency profile",
      currencyCode: aud.id,
      financialYearStartMonth: 7,
      instruments: [aud, usd, bhp, eth],
      accounts: makeMultiCurrencyAccounts(ids: ids, aud: aud, usd: usd, bhp: bhp, eth: eth),
      categories: [Category(id: ids.foodCategoryId, name: "Food")],
      earmarks: [
        Earmark(
          id: ids.earmarkId, name: "US Trip", instrument: usd,
          savingsGoal: InstrumentAmount(quantity: Decimal(string: "500")!, instrument: usd)
        )
      ],
      earmarkBudgets: [
        ids.earmarkId: [
          EarmarkBudgetItem(
            categoryId: ids.foodCategoryId,
            amount: InstrumentAmount(quantity: Decimal(string: "50")!, instrument: usd)
          )
        ]
      ],
      transactions: makeMultiCurrencyTransactions(ids: ids, aud: aud, usd: usd, bhp: bhp, eth: eth),
      investmentValues: makeMultiCurrencyInvestmentValues(ids: ids, bhp: bhp, eth: eth)
    )
  }

  private static func makeMultiCurrencyAccounts(
    ids: MultiCurrencyFixtureIds,
    aud: Instrument,
    usd: Instrument,
    bhp: Instrument,
    eth: Instrument
  ) -> [Account] {
    [
      Account(id: ids.audAccountId, name: "Checking AUD", type: .bank, instrument: aud),
      Account(id: ids.usdAccountId, name: "USD Travel", type: .bank, instrument: usd),
      Account(id: ids.investmentAccountId, name: "Brokerage", type: .investment, instrument: bhp),
      Account(id: ids.cryptoEarmarkAccountId, name: "Crypto Wallet", type: .asset, instrument: eth),
    ]
  }

  private static func makeMultiCurrencyTransactions(
    ids: MultiCurrencyFixtureIds,
    aud: Instrument,
    usd: Instrument,
    bhp: Instrument,
    eth: Instrument
  ) -> [Transaction] {
    [
      Transaction(
        date: Date(timeIntervalSince1970: 1_700_100_000),
        payee: "Coffee shop NYC",
        legs: [
          TransactionLeg(
            accountId: ids.usdAccountId, instrument: usd,
            quantity: Decimal(string: "-4.50")!, type: .expense,
            categoryId: ids.foodCategoryId, earmarkId: ids.earmarkId
          )
        ]
      ),
      Transaction(
        date: Date(timeIntervalSince1970: 1_700_200_000),
        payee: "Stock purchase",
        legs: [
          TransactionLeg(
            accountId: ids.audAccountId, instrument: aud,
            quantity: Decimal(string: "-1500.00")!, type: .transfer
          ),
          TransactionLeg(
            accountId: ids.investmentAccountId, instrument: bhp,
            quantity: Decimal(string: "10")!, type: .transfer
          ),
        ]
      ),
      Transaction(
        date: Date(timeIntervalSince1970: 1_700_300_000),
        payee: "Crypto swap",
        legs: [
          TransactionLeg(
            accountId: ids.cryptoEarmarkAccountId, instrument: eth,
            quantity: Decimal(string: "0.25")!, type: .income
          )
        ]
      ),
    ]
  }

  private static func makeMultiCurrencyInvestmentValues(
    ids: MultiCurrencyFixtureIds, bhp: Instrument, eth: Instrument
  ) -> [UUID: [InvestmentValue]] {
    [
      ids.investmentAccountId: [
        InvestmentValue(
          date: Date(timeIntervalSince1970: 1_700_400_000),
          value: InstrumentAmount(quantity: Decimal(string: "10")!, instrument: bhp)
        )
      ],
      ids.cryptoEarmarkAccountId: [
        InvestmentValue(
          date: Date(timeIntervalSince1970: 1_700_500_000),
          value: InstrumentAmount(quantity: Decimal(string: "0.25")!, instrument: eth)
        )
      ],
    ]
  }
}
