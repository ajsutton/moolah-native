import Foundation
import Testing

@testable import Moolah

@Suite("Instrument")
struct InstrumentTests {
  @Test func fiatInstrumentProperties() {
    let aud = Instrument.fiat(code: "AUD")
    #expect(aud.id == "AUD")
    #expect(aud.kind == .fiatCurrency)
    #expect(aud.name == "AUD")
    #expect(aud.decimals == 2)
  }

  @Test func fiatJPYHasZeroDecimals() {
    let jpy = Instrument.fiat(code: "JPY")
    #expect(jpy.id == "JPY")
    #expect(jpy.decimals == 0)
  }

  @Test func equality() {
    let a = Instrument.fiat(code: "AUD")
    let b = Instrument.fiat(code: "AUD")
    let c = Instrument.fiat(code: "USD")
    #expect(a == b)
    #expect(a != c)
  }

  @Test func hashable() {
    let a = Instrument.fiat(code: "AUD")
    let b = Instrument.fiat(code: "AUD")
    #expect(a.hashValue == b.hashValue)
  }

  @Test func codableRoundTrip() throws {
    let original = Instrument.fiat(code: "AUD")
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(Instrument.self, from: data)
    #expect(decoded == original)
  }

  @Test func currencySymbolDerivedFromLocale() {
    let aud = Instrument.fiat(code: "AUD")
    let symbol = aud.currencySymbol
    #expect(symbol != nil)
    #expect(!symbol!.isEmpty)
  }
}
