import Foundation
import Testing

@testable import Moolah

@Suite("InstrumentAmount")
struct InstrumentAmountTests {
  let aud = Instrument.AUD

  @Test func initStoresQuantityAndInstrument() {
    let amount = InstrumentAmount(quantity: Decimal(string: "50.23")!, instrument: aud)
    #expect(amount.quantity == Decimal(string: "50.23")!)
    #expect(amount.instrument == aud)
  }

  @Test func zeroFactory() {
    let zero = InstrumentAmount.zero(instrument: aud)
    #expect(zero.quantity == 0)
    #expect(zero.instrument == aud)
  }

  @Test func isPositiveNegativeZero() {
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

  @Test func addition() {
    let a = InstrumentAmount(quantity: Decimal(string: "1.50")!, instrument: aud)
    let b = InstrumentAmount(quantity: Decimal(string: "2.50")!, instrument: aud)
    let result = a + b
    #expect(result.quantity == Decimal(string: "4.00")!)
    #expect(result.instrument == aud)
  }

  @Test func subtraction() {
    let a = InstrumentAmount(quantity: Decimal(string: "5.00")!, instrument: aud)
    let b = InstrumentAmount(quantity: Decimal(string: "2.00")!, instrument: aud)
    #expect((a - b).quantity == Decimal(string: "3.00")!)
  }

  @Test func negation() {
    let a = InstrumentAmount(quantity: Decimal(string: "5.00")!, instrument: aud)
    #expect((-a).quantity == Decimal(string: "-5.00")!)
    #expect((-a).instrument == aud)
  }

  @Test func plusEquals() {
    var a = InstrumentAmount(quantity: Decimal(string: "1.00")!, instrument: aud)
    a += InstrumentAmount(quantity: Decimal(string: "0.50")!, instrument: aud)
    #expect(a.quantity == Decimal(string: "1.50")!)
  }

  @Test func comparison() {
    let a = InstrumentAmount(quantity: Decimal(string: "1.00")!, instrument: aud)
    let b = InstrumentAmount(quantity: Decimal(string: "2.00")!, instrument: aud)
    #expect(a < b)
    #expect(!(b < a))
  }

  @Test func decimalValue() {
    let amount = InstrumentAmount(quantity: Decimal(string: "50.23")!, instrument: aud)
    #expect(amount.decimalValue == Decimal(string: "50.23")!)
  }

  @Test func formattedFiat() {
    let amount = InstrumentAmount(quantity: Decimal(string: "50.23")!, instrument: aud)
    #expect(amount.formatted.contains("50.23"))
  }

  @Test func formattedStock() {
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let amount = InstrumentAmount(quantity: Decimal(string: "150")!, instrument: bhp)
    #expect(amount.formatted == "150 BHP.AX")
  }

  @Test func formattedStockFractional() {
    let aapl = Instrument.stock(ticker: "AAPL", exchange: "NASDAQ", name: "Apple", decimals: 4)
    let amount = InstrumentAmount(quantity: Decimal(string: "3.5000")!, instrument: aapl)
    #expect(amount.formatted == "3.5 AAPL")
  }

  @Test func formattedCrypto() {
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
    let amount = InstrumentAmount(quantity: Decimal(string: "0.5")!, instrument: eth)
    #expect(amount.formatted == "0.5 ETH")
  }

  @Test func formattedCryptoZero() {
    let btc = Instrument.crypto(
      chainId: 0, contractAddress: nil, symbol: "BTC", name: "Bitcoin", decimals: 8)
    let amount = InstrumentAmount(quantity: 0, instrument: btc)
    #expect(amount.formatted == "0 BTC")
  }

  @Test func formattedNegativeStock() {
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let amount = InstrumentAmount(quantity: Decimal(string: "-10")!, instrument: bhp)
    #expect(amount.formatted == "-10 BHP.AX")
  }

  @Test func formatNoSymbol() {
    let amount = InstrumentAmount(quantity: Decimal(string: "1234.56")!, instrument: aud)
    let text = amount.formatNoSymbol
    #expect(text.contains("1234.56") || text.contains("1,234.56"))
  }

  @Test func reduceForSumming() {
    let amounts = [
      InstrumentAmount(quantity: Decimal(string: "1.00")!, instrument: aud),
      InstrumentAmount(quantity: Decimal(string: "2.00")!, instrument: aud),
      InstrumentAmount(quantity: Decimal(string: "-0.50")!, instrument: aud),
    ]
    let total = amounts.reduce(.zero(instrument: aud)) { $0 + $1 }
    #expect(total.quantity == Decimal(string: "2.50")!)
  }

  @Test func equality() {
    let a = InstrumentAmount(quantity: Decimal(string: "1.00")!, instrument: .AUD)
    let b = InstrumentAmount(quantity: Decimal(string: "1.00")!, instrument: .AUD)
    let c = InstrumentAmount(quantity: Decimal(string: "1.00")!, instrument: .USD)
    #expect(a == b)
    #expect(a != c)
  }

  @Test func codableRoundTrip() throws {
    let original = InstrumentAmount(quantity: Decimal(string: "50.23")!, instrument: .AUD)
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(InstrumentAmount.self, from: data)
    #expect(decoded == original)
  }

  // MARK: - Storage Scaling

  @Test func toStorageValueScalesBy10e8() {
    let amount = InstrumentAmount(quantity: Decimal(string: "50.23")!, instrument: aud)
    #expect(amount.storageValue == 5_023_000_000)
  }

  @Test func fromStorageValueRoundTrips() {
    let original = InstrumentAmount(quantity: Decimal(string: "47046.61094572")!, instrument: aud)
    let stored = original.storageValue
    let restored = InstrumentAmount(storageValue: stored, instrument: aud)
    #expect(restored.quantity == Decimal(string: "47046.61094572")!)
  }

  @Test func storageValueZero() {
    let zero = InstrumentAmount.zero(instrument: aud)
    #expect(zero.storageValue == 0)
  }

  @Test func storageValueNegative() {
    let amount = InstrumentAmount(quantity: Decimal(string: "-50.23")!, instrument: aud)
    #expect(amount.storageValue == -5_023_000_000)
  }

  // MARK: - Parse

  @Test func parseQuantityWholeNumber() {
    #expect(InstrumentAmount.parseQuantity(from: "100", decimals: 2) == Decimal(string: "100"))
  }

  @Test func parseQuantityDecimal() {
    #expect(InstrumentAmount.parseQuantity(from: "12.50", decimals: 2) == Decimal(string: "12.50"))
  }

  @Test func parseQuantityStripsNonNumeric() {
    #expect(InstrumentAmount.parseQuantity(from: "$12.50", decimals: 2) == Decimal(string: "12.50"))
  }

  @Test func parseQuantityEmptyString() {
    #expect(InstrumentAmount.parseQuantity(from: "", decimals: 2) == nil)
  }

  @Test func parseQuantityInvalid() {
    #expect(InstrumentAmount.parseQuantity(from: "abc", decimals: 2) == nil)
  }

  @Test func parseQuantityMultipleDecimals() {
    #expect(InstrumentAmount.parseQuantity(from: "1.2.3", decimals: 2) == nil)
  }

  @Test func parseQuantityHandlesNegativeValues() {
    let result = InstrumentAmount.parseQuantity(from: "-25.50", decimals: 2)
    #expect(result == Decimal(string: "-25.50"))
  }

  @Test func parseQuantityHandlesZero() {
    let result = InstrumentAmount.parseQuantity(from: "0", decimals: 2)
    #expect(result == Decimal.zero)
  }

  @Test func parseQuantityHandlesNegativeZero() {
    let result = InstrumentAmount.parseQuantity(from: "-0", decimals: 2)
    #expect(result == Decimal.zero)
  }

  @Test func parseQuantityHandlesNegativeWithoutLeadingDigit() {
    let result = InstrumentAmount.parseQuantity(from: "-.50", decimals: 2)
    #expect(result == Decimal(string: "-0.5"))
  }

  @Test func parseQuantityStillRejectsNonNumeric() {
    let result = InstrumentAmount.parseQuantity(from: "abc", decimals: 2)
    #expect(result == nil)
  }

  @Test func parseQuantityStillRejectsEmpty() {
    let result = InstrumentAmount.parseQuantity(from: "", decimals: 2)
    #expect(result == nil)
  }

  // MARK: - Multi-instrument storage scaling

  @Test func storageRoundTripForCryptoEightDecimals() {
    let btc = Instrument.crypto(
      chainId: 0, contractAddress: nil, symbol: "BTC", name: "Bitcoin", decimals: 8
    )
    let original = InstrumentAmount(quantity: Decimal(string: "0.12345678")!, instrument: btc)
    #expect(original.storageValue == 12_345_678)
    let restored = InstrumentAmount(storageValue: original.storageValue, instrument: btc)
    #expect(restored.quantity == Decimal(string: "0.12345678")!)
    #expect(restored.instrument == btc)
  }

  @Test func storageRoundTripForCryptoSubSatoshiTruncates() {
    // 10^8 storage scale means anything below 8 decimals of precision is lost.
    // ETH declares 18 decimals but storage only preserves 8 — truncation is expected.
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18
    )
    let original = InstrumentAmount(
      quantity: Decimal(string: "0.123456789012345678")!, instrument: eth)
    // Only first 8 decimals survive Int64 × 10^8 storage scaling.
    let restored = InstrumentAmount(storageValue: original.storageValue, instrument: eth)
    #expect(restored.quantity == Decimal(string: "0.12345678")!)
  }

  @Test func storageRoundTripForStockWholeShares() {
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let amount = InstrumentAmount(quantity: Decimal(150), instrument: bhp)
    #expect(amount.storageValue == 15_000_000_000)
    let restored = InstrumentAmount(storageValue: amount.storageValue, instrument: bhp)
    #expect(restored.quantity == Decimal(150))
    #expect(restored.instrument == bhp)
  }

  @Test func storageRoundTripForZeroDecimalFiat() {
    let jpy = Instrument.fiat(code: "JPY")
    let amount = InstrumentAmount(quantity: Decimal(12345), instrument: jpy)
    #expect(amount.storageValue == 1_234_500_000_000)
    let restored = InstrumentAmount(storageValue: amount.storageValue, instrument: jpy)
    #expect(restored.quantity == Decimal(12345))
  }

  @Test func storageRoundTripForLargeCryptoQuantity() {
    // Simulate a wallet holding a large whole-token quantity; must survive Int64 bounds.
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18
    )
    let original = InstrumentAmount(quantity: Decimal(string: "1234567.89012345")!, instrument: eth)
    let restored = InstrumentAmount(storageValue: original.storageValue, instrument: eth)
    #expect(restored.quantity == Decimal(string: "1234567.89012345")!)
  }

  // MARK: - Formatting across instrument kinds

  @Test func formattedZeroDecimalFiatHasNoFractionPart() {
    // JPY is zero-decimal; formatting must not introduce decimals.
    let jpy = Instrument.fiat(code: "JPY")
    let amount = InstrumentAmount(quantity: Decimal(500), instrument: jpy)
    #expect(!amount.formatted.contains("."))
    #expect(amount.formatted.contains("500"))
  }

  @Test func formatNoSymbolRespectsCryptoDecimals() {
    let btc = Instrument.crypto(
      chainId: 0, contractAddress: nil, symbol: "BTC", name: "Bitcoin", decimals: 8
    )
    let amount = InstrumentAmount(quantity: Decimal(string: "0.5")!, instrument: btc)
    #expect(amount.formatNoSymbol == "0.50000000")
  }

  @Test func formatNoSymbolZeroDecimalFiatHasNoDecimals() {
    let jpy = Instrument.fiat(code: "JPY")
    let amount = InstrumentAmount(quantity: Decimal(500), instrument: jpy)
    #expect(amount.formatNoSymbol == "500")
  }

  // MARK: - Equality discriminates by instrument kind

  @Test func equalityDistinguishesBetweenKindsWithSameId() {
    // Hypothetical: a fiat code that collides with a stock ticker should be distinct.
    // This exercises the Hashable/Equatable contract on the full Instrument record, not just id.
    let fiat = Instrument.fiat(code: "USD")
    let stock = Instrument.stock(ticker: "USD.X", exchange: "USD", name: "USD")
    let a = InstrumentAmount(quantity: Decimal(10), instrument: fiat)
    let b = InstrumentAmount(quantity: Decimal(10), instrument: stock)
    #expect(a != b)
  }

  @Test func negationPreservesInstrumentAcrossKinds() {
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18
    )
    let amount = InstrumentAmount(quantity: Decimal(string: "0.5")!, instrument: eth)
    let negated = -amount
    #expect(negated.instrument == eth)
    #expect(negated.quantity == Decimal(string: "-0.5")!)
  }

  @Test func reduceForSummingCryptoPreservesPrecision() {
    let btc = Instrument.crypto(
      chainId: 0, contractAddress: nil, symbol: "BTC", name: "Bitcoin", decimals: 8
    )
    let amounts = [
      InstrumentAmount(quantity: Decimal(string: "0.00000001")!, instrument: btc),
      InstrumentAmount(quantity: Decimal(string: "0.00000002")!, instrument: btc),
      InstrumentAmount(quantity: Decimal(string: "0.00000003")!, instrument: btc),
    ]
    let total = amounts.reduce(.zero(instrument: btc)) { $0 + $1 }
    #expect(total.quantity == Decimal(string: "0.00000006")!)
  }
}
