import Foundation
import Testing

@testable import Moolah

@Suite("MonetaryAmount")
struct MonetaryAmountTests {
  @Test func initStoresCentsAndCurrency() {
    let amount = MonetaryAmount(cents: 5000, currency: Currency.AUD)
    #expect(amount.cents == 5000)
    #expect(amount.currency == Currency.AUD)
  }

  @Test func initDefaultsToDefaultCurrency() {
    let amount = MonetaryAmount(cents: 1000, currency: Currency.defaultTestCurrency)
    #expect(amount.currency == Currency.defaultTestCurrency)
  }

  @Test func zeroReturnsDefaultCurrency() {
    let zero = MonetaryAmount.zero(currency: .defaultTestCurrency)
    #expect(zero.cents == 0)
    #expect(zero.currency == Currency.defaultTestCurrency)
  }

  @Test func addition() {
    let a = MonetaryAmount(cents: 100, currency: Currency.AUD)
    let b = MonetaryAmount(cents: 250, currency: Currency.AUD)
    let result = a + b
    #expect(result.cents == 350)
    #expect(result.currency == Currency.AUD)
  }

  @Test func subtraction() {
    let a = MonetaryAmount(cents: 500, currency: Currency.AUD)
    let b = MonetaryAmount(cents: 200, currency: Currency.AUD)
    #expect((a - b).cents == 300)
  }

  @Test func negation() {
    let a = MonetaryAmount(cents: 500, currency: Currency.AUD)
    #expect((-a).cents == -500)
    #expect((-a).currency == Currency.AUD)
  }

  @Test func plusEquals() {
    var a = MonetaryAmount(cents: 100, currency: Currency.AUD)
    a += MonetaryAmount(cents: 50, currency: Currency.AUD)
    #expect(a.cents == 150)
  }

  @Test func comparison() {
    let a = MonetaryAmount(cents: 100, currency: Currency.AUD)
    let b = MonetaryAmount(cents: 200, currency: Currency.AUD)
    #expect(a < b)
    #expect(!(b < a))
  }

  @Test func isPositiveNegativeZero() {
    #expect(MonetaryAmount(cents: 1, currency: Currency.AUD).isPositive)
    #expect(!MonetaryAmount(cents: 1, currency: Currency.AUD).isNegative)
    #expect(!MonetaryAmount(cents: 1, currency: Currency.AUD).isZero)

    #expect(MonetaryAmount(cents: -1, currency: Currency.AUD).isNegative)
    #expect(!MonetaryAmount(cents: -1, currency: Currency.AUD).isPositive)

    #expect(MonetaryAmount(cents: 0, currency: Currency.AUD).isZero)
    #expect(!MonetaryAmount(cents: 0, currency: Currency.AUD).isPositive)
    #expect(!MonetaryAmount(cents: 0, currency: Currency.AUD).isNegative)
  }

  @Test func decimalValue() {
    let amount = MonetaryAmount(cents: 5023, currency: Currency.AUD)
    #expect(amount.decimalValue == Decimal(string: "50.23"))
  }

  @Test func reduceWorksForSumming() {
    let amounts = [
      MonetaryAmount(cents: 100, currency: Currency.AUD),
      MonetaryAmount(cents: 200, currency: Currency.AUD),
      MonetaryAmount(cents: -50, currency: Currency.AUD),
    ]
    let total = amounts.reduce(.zero(currency: .defaultTestCurrency)) { $0 + $1 }
    #expect(total.cents == 250)
  }

  @Test func equality() {
    let a = MonetaryAmount(cents: 100, currency: Currency.AUD)
    let b = MonetaryAmount(cents: 100, currency: Currency.AUD)
    let c = MonetaryAmount(cents: 100, currency: Currency.USD)
    #expect(a == b)
    #expect(a != c)
  }

  // MARK: - parseCents(from:)

  @Test func parseCentsWholeNumber() {
    #expect(MonetaryAmount.parseCents(from: "100") == 10000)
  }

  @Test func parseCentsDecimal() {
    #expect(MonetaryAmount.parseCents(from: "12.50") == 1250)
  }

  @Test func parseCentsStripsNonNumeric() {
    #expect(MonetaryAmount.parseCents(from: "$12.50") == 1250)
  }

  @Test func parseCentsEmptyString() {
    #expect(MonetaryAmount.parseCents(from: "") == nil)
  }

  @Test func parseCentsInvalidString() {
    #expect(MonetaryAmount.parseCents(from: "abc") == nil)
  }

  @Test func parseCentsMultipleDecimals() {
    #expect(MonetaryAmount.parseCents(from: "1.2.3") == nil)
  }

  @Test func parseCentsZero() {
    #expect(MonetaryAmount.parseCents(from: "0") == 0)
  }
}
