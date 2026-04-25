import Foundation
import Testing

@testable import Moolah

@Suite("Instrument.preferredCurrencySymbol")
struct InstrumentSymbolTests {
  @Test("USD resolves to $ regardless of host locale")
  func usdSymbol() {
    #expect(Instrument.preferredCurrencySymbol(for: "USD") == "$")
  }

  @Test("GBP resolves to £")
  func gbpSymbol() {
    #expect(Instrument.preferredCurrencySymbol(for: "GBP") == "£")
  }

  @Test("EUR resolves to €")
  func eurSymbol() {
    #expect(Instrument.preferredCurrencySymbol(for: "EUR") == "€")
  }

  @Test("AUD resolves to $ via en_AU locale")
  func audSymbol() {
    #expect(Instrument.preferredCurrencySymbol(for: "AUD") == "$")
  }

  @Test("JPY resolves to ¥")
  func jpySymbol() {
    #expect(Instrument.preferredCurrencySymbol(for: "JPY") == "¥")
  }

  @Test("Unknown ISO code returns nil")
  func unknownCodeReturnsNil() {
    #expect(Instrument.preferredCurrencySymbol(for: "ZZZ") == nil)
  }

  @Test("Instance currencySymbol delegates to helper for fiat")
  func instanceSymbolDelegatesForFiat() {
    let usd = Instrument.fiat(code: "USD")
    #expect(usd.currencySymbol == "$")
  }

  @Test("Instance currencySymbol returns nil for non-fiat")
  func instanceSymbolNilForStock() {
    let stock = Instrument.stock(ticker: "AAPL", exchange: "NASDAQ", name: "Apple")
    #expect(stock.currencySymbol == nil)
  }
}
