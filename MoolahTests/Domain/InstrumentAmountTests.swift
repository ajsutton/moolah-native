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

  @Test func formatted() {
    let amount = InstrumentAmount(quantity: Decimal(string: "50.23")!, instrument: aud)
    #expect(amount.formatted.contains("50.23"))
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
}
