import Foundation
import Testing

@testable import Moolah

@Suite("MonetaryAmount")
struct MonetaryAmountTests {
  @Test func initStoresCentsAndCurrency() {
    let amount = MonetaryAmount(cents: 5000, currency: "AUD")
    #expect(amount.cents == 5000)
    #expect(amount.currency == "AUD")
  }

  @Test func initDefaultsToDefaultCurrency() {
    let amount = MonetaryAmount(cents: 1000)
    #expect(amount.currency == Constants.defaultCurrency)
  }

  @Test func zeroReturnsDefaultCurrency() {
    let zero = MonetaryAmount.zero
    #expect(zero.cents == 0)
    #expect(zero.currency == Constants.defaultCurrency)
  }

  @Test func addition() {
    let a = MonetaryAmount(cents: 100, currency: "AUD")
    let b = MonetaryAmount(cents: 250, currency: "AUD")
    let result = a + b
    #expect(result.cents == 350)
    #expect(result.currency == "AUD")
  }

  @Test func subtraction() {
    let a = MonetaryAmount(cents: 500, currency: "AUD")
    let b = MonetaryAmount(cents: 200, currency: "AUD")
    #expect((a - b).cents == 300)
  }

  @Test func negation() {
    let a = MonetaryAmount(cents: 500, currency: "AUD")
    #expect((-a).cents == -500)
    #expect((-a).currency == "AUD")
  }

  @Test func plusEquals() {
    var a = MonetaryAmount(cents: 100, currency: "AUD")
    a += MonetaryAmount(cents: 50, currency: "AUD")
    #expect(a.cents == 150)
  }

  @Test func comparison() {
    let a = MonetaryAmount(cents: 100, currency: "AUD")
    let b = MonetaryAmount(cents: 200, currency: "AUD")
    #expect(a < b)
    #expect(!(b < a))
  }

  @Test func isPositiveNegativeZero() {
    #expect(MonetaryAmount(cents: 1, currency: "AUD").isPositive)
    #expect(!MonetaryAmount(cents: 1, currency: "AUD").isNegative)
    #expect(!MonetaryAmount(cents: 1, currency: "AUD").isZero)

    #expect(MonetaryAmount(cents: -1, currency: "AUD").isNegative)
    #expect(!MonetaryAmount(cents: -1, currency: "AUD").isPositive)

    #expect(MonetaryAmount(cents: 0, currency: "AUD").isZero)
    #expect(!MonetaryAmount(cents: 0, currency: "AUD").isPositive)
    #expect(!MonetaryAmount(cents: 0, currency: "AUD").isNegative)
  }

  @Test func decimalValue() {
    let amount = MonetaryAmount(cents: 5023, currency: "AUD")
    #expect(amount.decimalValue == Decimal(string: "50.23"))
  }

  @Test func reduceWorksForSumming() {
    let amounts = [
      MonetaryAmount(cents: 100, currency: "AUD"),
      MonetaryAmount(cents: 200, currency: "AUD"),
      MonetaryAmount(cents: -50, currency: "AUD"),
    ]
    let total = amounts.reduce(.zero) { $0 + $1 }
    #expect(total.cents == 250)
  }

  @Test func equality() {
    let a = MonetaryAmount(cents: 100, currency: "AUD")
    let b = MonetaryAmount(cents: 100, currency: "AUD")
    let c = MonetaryAmount(cents: 100, currency: "USD")
    #expect(a == b)
    #expect(a != c)
  }
}
