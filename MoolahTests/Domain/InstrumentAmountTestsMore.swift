import Foundation
import Testing

@testable import Moolah

@Suite("InstrumentAmount — Part 2")
struct InstrumentAmountTestsMore {
  @Test
  func parseQuantityWholeNumber() {
    #expect(InstrumentAmount.parseQuantity(from: "100", decimals: 2) == Decimal(string: "100"))
  }

  @Test
  func parseQuantityDecimal() {
    #expect(InstrumentAmount.parseQuantity(from: "12.50", decimals: 2) == Decimal(string: "12.50"))
  }

  @Test
  func parseQuantityStripsNonNumeric() {
    #expect(InstrumentAmount.parseQuantity(from: "$12.50", decimals: 2) == Decimal(string: "12.50"))
  }

  @Test
  func parseQuantityEmptyString() {
    #expect(InstrumentAmount.parseQuantity(from: "", decimals: 2) == nil)
  }

  @Test
  func parseQuantityInvalid() {
    #expect(InstrumentAmount.parseQuantity(from: "abc", decimals: 2) == nil)
  }

  @Test
  func parseQuantityMultipleDecimals() {
    #expect(InstrumentAmount.parseQuantity(from: "1.2.3", decimals: 2) == nil)
  }

  @Test
  func parseQuantityHandlesNegativeValues() {
    let result = InstrumentAmount.parseQuantity(from: "-25.50", decimals: 2)
    #expect(result == Decimal(string: "-25.50"))
  }

  @Test
  func parseQuantityHandlesZero() {
    let result = InstrumentAmount.parseQuantity(from: "0", decimals: 2)
    #expect(result == Decimal.zero)
  }

  @Test
  func parseQuantityHandlesNegativeZero() {
    let result = InstrumentAmount.parseQuantity(from: "-0", decimals: 2)
    #expect(result == Decimal.zero)
  }

  @Test
  func parseQuantityHandlesNegativeWithoutLeadingDigit() {
    let result = InstrumentAmount.parseQuantity(from: "-.50", decimals: 2)
    #expect(result == Decimal(string: "-0.5"))
  }

  @Test
  func parseQuantityStillRejectsNonNumeric() {
    let result = InstrumentAmount.parseQuantity(from: "abc", decimals: 2)
    #expect(result == nil)
  }

  @Test
  func parseQuantityStillRejectsEmpty() {
    let result = InstrumentAmount.parseQuantity(from: "", decimals: 2)
    #expect(result == nil)
  }

  // MARK: - Multi-instrument storage scaling

  @Test
  func storageRoundTripForCryptoEightDecimals() {
    let btc = Instrument.crypto(
      chainId: 0, contractAddress: nil, symbol: "BTC", name: "Bitcoin", decimals: 8
    )
    let original = InstrumentAmount(quantity: Decimal(string: "0.12345678")!, instrument: btc)
    #expect(original.storageValue == 12_345_678)
    let restored = InstrumentAmount(storageValue: original.storageValue, instrument: btc)
    #expect(restored.quantity == Decimal(string: "0.12345678")!)
    #expect(restored.instrument == btc)
  }

  @Test
  func storageRoundTripForCryptoSubSatoshiTruncates() {
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

  @Test
  func storageRoundTripForStockWholeShares() {
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let amount = InstrumentAmount(quantity: Decimal(150), instrument: bhp)
    #expect(amount.storageValue == 15_000_000_000)
    let restored = InstrumentAmount(storageValue: amount.storageValue, instrument: bhp)
    #expect(restored.quantity == Decimal(150))
    #expect(restored.instrument == bhp)
  }

  @Test
  func storageRoundTripForZeroDecimalFiat() {
    let jpy = Instrument.fiat(code: "JPY")
    let amount = InstrumentAmount(quantity: Decimal(12345), instrument: jpy)
    #expect(amount.storageValue == 1_234_500_000_000)
    let restored = InstrumentAmount(storageValue: amount.storageValue, instrument: jpy)
    #expect(restored.quantity == Decimal(12345))
  }

  @Test
  func storageRoundTripForLargeCryptoQuantity() {
    // Simulate first wallet holding first large whole-token quantity; must survive Int64 bounds.
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18
    )
    let original = InstrumentAmount(quantity: Decimal(string: "1234567.89012345")!, instrument: eth)
    let restored = InstrumentAmount(storageValue: original.storageValue, instrument: eth)
    #expect(restored.quantity == Decimal(string: "1234567.89012345")!)
  }

  // MARK: - Formatting across instrument kinds

  @Test
  func formattedZeroDecimalFiatHasNoFractionPart() {
    // JPY is zero-decimal; formatting must not introduce decimals.
    let jpy = Instrument.fiat(code: "JPY")
    let amount = InstrumentAmount(quantity: Decimal(500), instrument: jpy)
    #expect(!amount.formatted.contains("."))
    #expect(amount.formatted.contains("500"))
  }

  @Test
  func formatNoSymbolRespectsCryptoDecimals() {
    let btc = Instrument.crypto(
      chainId: 0, contractAddress: nil, symbol: "BTC", name: "Bitcoin", decimals: 8
    )
    let amount = InstrumentAmount(quantity: Decimal(string: "0.5")!, instrument: btc)
    #expect(amount.formatNoSymbol == "0.50000000")
  }

  @Test
  func formatNoSymbolZeroDecimalFiatHasNoDecimals() {
    let jpy = Instrument.fiat(code: "JPY")
    let amount = InstrumentAmount(quantity: Decimal(500), instrument: jpy)
    #expect(amount.formatNoSymbol == "500")
  }

  // MARK: - Equality discriminates by instrument kind

  @Test
  func equalityDistinguishesBetweenKindsWithSameId() {
    // Hypothetical: first fiat code that collides with first stock ticker should be distinct.
    // This exercises the Hashable/Equatable contract on the full Instrument record, not just id.
    let fiat = Instrument.fiat(code: "USD")
    let stock = Instrument.stock(ticker: "USD.X", exchange: "USD", name: "USD")
    let first = InstrumentAmount(quantity: Decimal(10), instrument: fiat)
    let second = InstrumentAmount(quantity: Decimal(10), instrument: stock)
    #expect(first != second)
  }

  @Test
  func negationPreservesInstrumentAcrossKinds() {
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18
    )
    let amount = InstrumentAmount(quantity: Decimal(string: "0.5")!, instrument: eth)
    let negated = -amount
    #expect(negated.instrument == eth)
    #expect(negated.quantity == Decimal(string: "-0.5")!)
  }

  @Test
  func reduceForSummingCryptoPreservesPrecision() {
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
