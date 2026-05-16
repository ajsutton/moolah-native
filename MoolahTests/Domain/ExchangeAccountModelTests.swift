import Testing

@testable import Moolah

struct ExchangeAccountModelTests {
  @Test
  func exchangeTypeIsInvestmentLikeNotCurrent() {
    #expect(AccountType.exchange.isInvestmentLike)
    #expect(!AccountType.exchange.isCurrent)
    #expect(AccountType.exchange.rawValue == "exchange")
    #expect(AccountType.exchange.displayName == "Exchange")
    #expect(AccountType.allCases.contains(.exchange))
  }

  @Test
  func accountCarriesExchangeProvider() {
    let account = Account(
      name: "Coinstash", type: .exchange, instrument: .AUD,
      exchangeProvider: .coinstash)
    #expect(account.exchangeProvider == .coinstash)
  }

  @Test
  func dataFormatVersionBumpedForExchange() {
    #expect(DataFormatVersion.current == 2)
  }
}
