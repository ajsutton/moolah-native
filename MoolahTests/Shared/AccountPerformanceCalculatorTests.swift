import Foundation
import Testing

@testable import Moolah

@Suite("AccountPerformanceCalculator.compute")
struct AccountPerformanceCalculatorTests {
  let aud = Instrument.AUD

  /// Account opened with $10,000 a year ago, current value $11,000 →
  /// contributions $10,000, P/L $1,000, p.a. ≈ 10%.
  @Test("opening balance only with growth surfaces P/L and annualised return")
  func openingBalanceOnly() async throws {
    let accountId = UUID()
    let aYearAgo = Date().addingTimeInterval(-365 * 86_400)
    let openingTxn = Transaction(
      date: aYearAgo,
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: 10_000, type: .openingBalance)
      ]
    )
    let valued = [
      ValuedPosition(
        instrument: aud, quantity: 11_000,
        unitPrice: nil, costBasis: nil,
        value: InstrumentAmount(quantity: 11_000, instrument: aud))
    ]

    let perf = try await AccountPerformanceCalculator.compute(
      accountId: accountId,
      transactions: [openingTxn],
      valuedPositions: valued,
      profileCurrency: aud,
      conversionService: FixedConversionService()
    )

    #expect(perf.currentValue == InstrumentAmount(quantity: 11_000, instrument: aud))
    #expect(perf.totalContributions == InstrumentAmount(quantity: 10_000, instrument: aud))
    #expect(perf.profitLoss == InstrumentAmount(quantity: 1_000, instrument: aud))
    let percent = try #require(perf.profitLossPercent)
    #expect(abs(Double(truncating: percent as NSDecimalNumber) - 0.10) < 0.001)
    let annualised = try #require(perf.annualisedReturn)
    #expect(abs(Double(truncating: annualised as NSDecimalNumber) - 0.10) < 0.005)
    #expect(perf.firstFlowDate == aYearAgo)
  }
}
