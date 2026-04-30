import Foundation
import Testing

@testable import Moolah

@Suite("AccountPerformanceCalculator.compute")
struct AccountPerformanceCalculatorTests {
  let aud = Instrument.AUD

  /// Fixture: account opened with $10,000 exactly one year before `now`,
  /// terminal value $11,000.
  private struct OpeningBalanceFixture {
    let accountId = UUID()
    let openingDate = Date(timeIntervalSinceReferenceDate: 0)
    var now: Date { openingDate.addingTimeInterval(365 * 86_400) }
    let transactions: [Transaction]
    let valued: [ValuedPosition]

    init(aud: Instrument) {
      let accountId = self.accountId
      transactions = [
        Transaction(
          date: openingDate,
          legs: [
            TransactionLeg(
              accountId: accountId, instrument: aud, quantity: 10_000, type: .openingBalance)
          ]
        )
      ]
      valued = [
        ValuedPosition(
          instrument: aud, quantity: 11_000,
          unitPrice: nil, costBasis: nil,
          value: InstrumentAmount(quantity: 11_000, instrument: aud))
      ]
    }
  }

  @Test("opening balance with growth records contributions, P/L, and first flow date")
  func openingBalanceContributionsAndProfitLoss() async throws {
    let fixture = OpeningBalanceFixture(aud: aud)
    let perf = try await AccountPerformanceCalculator.compute(
      accountId: fixture.accountId,
      transactions: fixture.transactions,
      valuedPositions: fixture.valued,
      profileCurrency: aud,
      conversionService: FixedConversionService(),
      now: fixture.now
    )
    #expect(perf.currentValue == InstrumentAmount(quantity: 11_000, instrument: aud))
    #expect(perf.totalContributions == InstrumentAmount(quantity: 10_000, instrument: aud))
    #expect(perf.profitLoss == InstrumentAmount(quantity: 1_000, instrument: aud))
    #expect(perf.firstFlowDate == fixture.openingDate)
  }

  @Test("opening balance with 10 percent growth records 10 percent Modified Dietz return")
  func openingBalanceModifiedDietzPercent() async throws {
    let fixture = OpeningBalanceFixture(aud: aud)
    let perf = try await AccountPerformanceCalculator.compute(
      accountId: fixture.accountId,
      transactions: fixture.transactions,
      valuedPositions: fixture.valued,
      profileCurrency: aud,
      conversionService: FixedConversionService(),
      now: fixture.now
    )
    let percent = try #require(perf.profitLossPercent)
    // Modified Dietz with one flow at t=0 and weighted-capital == ΣC = 10_000
    // is exactly (V − ΣC) / ΣC = 1000 / 10000 = 0.1.
    #expect(percent == Decimal(string: "0.1"))
  }

  @Test("opening balance with 10 percent growth converges on 10 percent annualised")
  func openingBalanceAnnualisedReturn() async throws {
    let fixture = OpeningBalanceFixture(aud: aud)
    let perf = try await AccountPerformanceCalculator.compute(
      accountId: fixture.accountId,
      transactions: fixture.transactions,
      valuedPositions: fixture.valued,
      profileCurrency: aud,
      conversionService: FixedConversionService(),
      now: fixture.now
    )
    let annualised = try #require(perf.annualisedReturn)
    let asDouble = Double(truncating: annualised as NSDecimalNumber)
    #expect(abs(asDouble - 0.10) < 0.001, "expected ~0.10, got \(asDouble)")
  }
}
