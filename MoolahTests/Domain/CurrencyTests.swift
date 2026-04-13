import Testing

@testable import Moolah

@Suite("Currency")
struct CurrencyTests {
  @Test func fromCode_AUD() {
    let currency = Currency.from(code: "AUD")
    #expect(currency.code == "AUD")
    #expect(currency.decimals == 2)
    #expect(!currency.symbol.isEmpty)
  }

  @Test func fromCode_USD() {
    let currency = Currency.from(code: "USD")
    #expect(currency.code == "USD")
    #expect(currency.decimals == 2)
  }

  @Test func fromCode_JPY() {
    let currency = Currency.from(code: "JPY")
    #expect(currency.code == "JPY")
    #expect(currency.decimals == 0)
  }

  @Test func fromCode_unknownCode() {
    let currency = Currency.from(code: "BTC")
    #expect(currency.code == "BTC")
    #expect(!currency.symbol.isEmpty)
  }

  @Test func fromCode_emptyCode() {
    let currency = Currency.from(code: "")
    #expect(currency.code == "")
  }

  @Test func fromCode_sameCodeReturnsSameResult() {
    let a = Currency.from(code: "AUD")
    let b = Currency.from(code: "AUD")
    #expect(a == b)
  }

  @Test func fromCode_differentCodes() {
    let aud = Currency.from(code: "AUD")
    let usd = Currency.from(code: "USD")
    #expect(aud.code != usd.code)
  }
}
