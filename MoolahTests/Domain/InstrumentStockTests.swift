import Foundation
import Testing

@testable import Moolah

@Suite("Instrument — Stock")
struct InstrumentStockTests {
  @Test
  func stockInstrumentProperties() {
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    #expect(bhp.id == "ASX:BHP")
    #expect(bhp.kind == .stock)
    #expect(bhp.name == "BHP")
    #expect(bhp.decimals == 0)
    #expect(bhp.ticker == "BHP.AX")
    #expect(bhp.exchange == "ASX")
    #expect(bhp.chainId == nil)
    #expect(bhp.contractAddress == nil)
  }

  @Test
  func stockIdUsesExchangeColonName() {
    let aapl = Instrument.stock(ticker: "AAPL", exchange: "NASDAQ", name: "Apple")
    #expect(aapl.id == "NASDAQ:Apple")
  }

  @Test
  func stockDecimalsDefaultToZero() {
    let stock = Instrument.stock(ticker: "VAS.AX", exchange: "ASX", name: "VAS")
    #expect(stock.decimals == 0)
  }

  @Test
  func stockWithCustomDecimals() {
    let stock = Instrument.stock(
      ticker: "BTC-USD", exchange: "CRYPTO", name: "BTC-USD", decimals: 8)
    #expect(stock.decimals == 8)
  }

  @Test
  func stockCurrencySymbolIsNil() {
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    #expect(bhp.currencySymbol == nil)
  }

  @Test
  func stockCodableRoundTrip() throws {
    let original = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(Instrument.self, from: data)
    #expect(decoded == original)
    #expect(decoded.ticker == "BHP.AX")
    #expect(decoded.exchange == "ASX")
  }

  @Test
  func stockEquality() {
    let a = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let b = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let c = Instrument.stock(ticker: "CBA.AX", exchange: "ASX", name: "CBA")
    #expect(a == b)
    #expect(a != c)
  }

  @Test
  func stockHashable() {
    let a = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let b = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    #expect(a.hashValue == b.hashValue)
  }

  // MARK: - Edge-case ticker formats

  @Test
  func stockWithDottedTicker() {
    // Berkshire Hathaway Class B — ticker contains dot.
    let brkB = Instrument.stock(ticker: "BRK.B", exchange: "NYSE", name: "BRK-B")
    #expect(brkB.ticker == "BRK.B")
    #expect(brkB.id == "NYSE:BRK-B")
  }

  @Test
  func stockWithHyphenatedTicker() {
    // BRK-A on some feeds uses hyphen.
    let brkA = Instrument.stock(ticker: "BRK-A", exchange: "NYSE", name: "BRK-A")
    #expect(brkA.ticker == "BRK-A")
  }

  @Test
  func stocksOnSameExchangeDifferByName() {
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let cba = Instrument.stock(ticker: "CBA.AX", exchange: "ASX", name: "CBA")
    #expect(bhp.id != cba.id)
    #expect(bhp != cba)
  }

  @Test
  func stockOnDifferentExchangesWithSameNameAreDistinct() {
    // Same name on two exchanges must have distinct ids — the exchange is part of identity.
    let aud = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let lon = Instrument.stock(ticker: "BHP.L", exchange: "LSE", name: "BHP")
    #expect(aud.id != lon.id)
    #expect(aud != lon)
  }
}
