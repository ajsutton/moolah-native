import Foundation
import Testing

@testable import Moolah

@Suite("InstrumentAmount")
struct InstrumentAmountTests {
  let aud = Instrument.AUD

  @Test
  func initStoresQuantityAndInstrument() {
    let amount = InstrumentAmount(quantity: Decimal(string: "50.23")!, instrument: aud)
    #expect(amount.quantity == Decimal(string: "50.23")!)
    #expect(amount.instrument == aud)
  }

  @Test
  func zeroFactory() {
    let zero = InstrumentAmount.zero(instrument: aud)
    #expect(zero.quantity == 0)
    #expect(zero.instrument == aud)
  }

  @Test
  func isPositiveNegativeZero() {
    let positive = InstrumentAmount(quantity: Decimal(string: "1.00")!, instrument: aud)
    #expect(positive.isPositive)
    #expect(!positive.isNegative)
    #expect(!positive.isZero)

    let negative = InstrumentAmount(quantity: Decimal(string: "-1.00")!, instrument: aud)
    #expect(negative.isNegative)
    #expect(!negative.isPositive)

    let zero = InstrumentAmount.zero(instrument: aud)
    #expect(zero.isZero)
    #expect(!zero.isPositive)
    #expect(!zero.isNegative)
  }

  @Test
  func addition() {
    let first = InstrumentAmount(quantity: Decimal(string: "1.50")!, instrument: aud)
    let second = InstrumentAmount(quantity: Decimal(string: "2.50")!, instrument: aud)
    let result = first + second
    #expect(result.quantity == Decimal(string: "4.00")!)
    #expect(result.instrument == aud)
  }

  @Test
  func subtraction() {
    let first = InstrumentAmount(quantity: Decimal(string: "5.00")!, instrument: aud)
    let second = InstrumentAmount(quantity: Decimal(string: "2.00")!, instrument: aud)
    #expect((first - second).quantity == Decimal(string: "3.00")!)
  }

  @Test
  func negation() {
    let first = InstrumentAmount(quantity: Decimal(string: "5.00")!, instrument: aud)
    #expect((-first).quantity == Decimal(string: "-5.00")!)
    #expect((-first).instrument == aud)
  }

  @Test
  func plusEquals() {
    var first = InstrumentAmount(quantity: Decimal(string: "1.00")!, instrument: aud)
    first += InstrumentAmount(quantity: Decimal(string: "0.50")!, instrument: aud)
    #expect(first.quantity == Decimal(string: "1.50")!)
  }

  @Test
  func comparison() {
    let first = InstrumentAmount(quantity: Decimal(string: "1.00")!, instrument: aud)
    let second = InstrumentAmount(quantity: Decimal(string: "2.00")!, instrument: aud)
    #expect(first < second)
    #expect(!(second < first))
  }

  @Test
  func decimalValue() {
    let amount = InstrumentAmount(quantity: Decimal(string: "50.23")!, instrument: aud)
    #expect(amount.decimalValue == Decimal(string: "50.23")!)
  }

  @Test
  func formattedFiat() {
    let amount = InstrumentAmount(quantity: Decimal(string: "50.23")!, instrument: aud)
    #expect(amount.formatted.contains("50.23"))
  }

  @Test
  func formattedStock() {
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let amount = InstrumentAmount(quantity: Decimal(string: "150")!, instrument: bhp)
    #expect(amount.formatted == "150 BHP.AX")
  }

  @Test
  func formattedStockFractional() {
    let aapl = Instrument.stock(ticker: "AAPL", exchange: "NASDAQ", name: "Apple", decimals: 4)
    let amount = InstrumentAmount(quantity: Decimal(string: "3.5000")!, instrument: aapl)
    #expect(amount.formatted == "3.5 AAPL")
  }

  @Test
  func formattedCrypto() {
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
    let amount = InstrumentAmount(quantity: Decimal(string: "0.5")!, instrument: eth)
    #expect(amount.formatted == "0.5 ETH")
  }

  @Test
  func formattedCryptoZero() {
    let btc = Instrument.crypto(
      chainId: 0, contractAddress: nil, symbol: "BTC", name: "Bitcoin", decimals: 8)
    let amount = InstrumentAmount(quantity: 0, instrument: btc)
    #expect(amount.formatted == "0 BTC")
  }

  @Test
  func formattedNegativeStock() {
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let amount = InstrumentAmount(quantity: Decimal(string: "-10")!, instrument: bhp)
    #expect(amount.formatted == "-10 BHP.AX")
  }

  @Test
  func formatNoSymbol() {
    let amount = InstrumentAmount(quantity: Decimal(string: "1234.56")!, instrument: aud)
    let text = amount.formatNoSymbol
    #expect(text.contains("1234.56") || text.contains("1,234.56"))
  }

  @Test
  func reduceForSumming() {
    let amounts = [
      InstrumentAmount(quantity: Decimal(string: "1.00")!, instrument: aud),
      InstrumentAmount(quantity: Decimal(string: "2.00")!, instrument: aud),
      InstrumentAmount(quantity: Decimal(string: "-0.50")!, instrument: aud),
    ]
    let total = amounts.reduce(.zero(instrument: aud)) { $0 + $1 }
    #expect(total.quantity == Decimal(string: "2.50")!)
  }

  @Test
  func equality() {
    let first = InstrumentAmount(quantity: Decimal(string: "1.00")!, instrument: .AUD)
    let second = InstrumentAmount(quantity: Decimal(string: "1.00")!, instrument: .AUD)
    let third = InstrumentAmount(quantity: Decimal(string: "1.00")!, instrument: .USD)
    #expect(first == second)
    #expect(first != third)
  }

  @Test
  func codableRoundTrip() throws {
    let original = InstrumentAmount(quantity: Decimal(string: "50.23")!, instrument: .AUD)
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(InstrumentAmount.self, from: data)
    #expect(decoded == original)
  }

  // MARK: - Storage Scaling

  @Test
  func toStorageValueScalesBy10e8() {
    let amount = InstrumentAmount(quantity: Decimal(string: "50.23")!, instrument: aud)
    #expect(amount.storageValue == 5_023_000_000)
  }

  @Test
  func fromStorageValueRoundTrips() {
    let original = InstrumentAmount(quantity: Decimal(string: "47046.61094572")!, instrument: aud)
    let stored = original.storageValue
    let restored = InstrumentAmount(storageValue: stored, instrument: aud)
    #expect(restored.quantity == Decimal(string: "47046.61094572")!)
  }

  @Test
  func storageValueZero() {
    let zero = InstrumentAmount.zero(instrument: aud)
    #expect(zero.storageValue == 0)
  }

  @Test
  func storageValueNegative() {
    let amount = InstrumentAmount(quantity: Decimal(string: "-50.23")!, instrument: aud)
    #expect(amount.storageValue == -5_023_000_000)
  }

  // MARK: - Parse
}
