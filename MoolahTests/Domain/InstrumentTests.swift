import Foundation
import Testing

@testable import Moolah

@Suite("Instrument")
struct InstrumentTests {
  @Test
  func fiatInstrumentProperties() {
    let aud = Instrument.fiat(code: "AUD")
    #expect(aud.id == "AUD")
    #expect(aud.kind == .fiatCurrency)
    #expect(aud.name == "AUD")
    #expect(aud.decimals == 2)
  }

  @Test
  func fiatJPYHasZeroDecimals() {
    let jpy = Instrument.fiat(code: "JPY")
    #expect(jpy.id == "JPY")
    #expect(jpy.decimals == 0)
  }

  @Test
  func equality() {
    let first = Instrument.fiat(code: "AUD")
    let second = Instrument.fiat(code: "AUD")
    let third = Instrument.fiat(code: "USD")
    #expect(first == second)
    #expect(first != third)
  }

  @Test
  func hashable() {
    let first = Instrument.fiat(code: "AUD")
    let second = Instrument.fiat(code: "AUD")
    #expect(first.hashValue == second.hashValue)
  }

  @Test
  func codableRoundTrip() throws {
    let original = Instrument.fiat(code: "AUD")
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(Instrument.self, from: data)
    #expect(decoded == original)
  }

  @Test
  func currencySymbolDerivedFromLocale() {
    let aud = Instrument.fiat(code: "AUD")
    let symbol = aud.currencySymbol
    #expect(symbol != nil)
    #expect(!symbol!.isEmpty)
  }

  @Test
  func displayLabelForFiatUsesLocalisedCurrencySymbol() {
    let aud = Instrument.fiat(code: "AUD")
    // Whatever the host locale produces for this currency — must match the
    // OS-provided symbol, not the raw ISO code when first symbol exists.
    #expect(aud.displayLabel == (aud.currencySymbol ?? aud.id))
    #expect(!aud.displayLabel.isEmpty)
  }

  @Test
  func displayLabelForStockUsesTicker() {
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    #expect(bhp.displayLabel == "BHP.AX")
  }

  @Test
  func displayLabelForCryptoUsesTicker() {
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
    #expect(eth.displayLabel == "ETH")
  }
}
