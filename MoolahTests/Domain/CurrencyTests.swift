import Foundation
import Testing

@testable import Moolah

@Suite("Currency")
struct CurrencyTests {
  @Test func audHasCorrectCode() {
    let currency = Currency.from(code: "AUD")
    #expect(currency.code == "AUD")
  }

  @Test func audHasTwoDecimals() {
    let currency = Currency.from(code: "AUD")
    #expect(currency.decimals == 2)
  }

  @Test func audHasNonEmptySymbol() {
    let currency = Currency.from(code: "AUD")
    #expect(!currency.symbol.isEmpty)
  }

  @Test func usdHasCorrectCode() {
    let currency = Currency.from(code: "USD")
    #expect(currency.code == "USD")
  }

  @Test func usdHasTwoDecimals() {
    let currency = Currency.from(code: "USD")
    #expect(currency.decimals == 2)
  }

  @Test func jpyHasCorrectCode() {
    let currency = Currency.from(code: "JPY")
    #expect(currency.code == "JPY")
  }

  @Test func jpyHasZeroDecimals() {
    let currency = Currency.from(code: "JPY")
    #expect(currency.decimals == 0)
  }

  @Test func unknownCodeFallsBackToCode() {
    let currency = Currency.from(code: "BTC")
    #expect(currency.code == "BTC")
    // Symbol falls back to code when unknown
    #expect(!currency.symbol.isEmpty)
  }

  @Test func emptyCodeDoesNotCrash() {
    let currency = Currency.from(code: "")
    #expect(currency.code == "")
  }

  @Test func sameCodeReturnsSameResult() {
    let first = Currency.from(code: "AUD")
    let second = Currency.from(code: "AUD")
    #expect(first.code == second.code)
    #expect(first.symbol == second.symbol)
    #expect(first.decimals == second.decimals)
  }

  @Test func differentCodesReturnDifferentResults() {
    let aud = Currency.from(code: "AUD")
    let usd = Currency.from(code: "USD")
    #expect(aud.code != usd.code)
  }
}
