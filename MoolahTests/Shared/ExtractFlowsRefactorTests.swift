import Foundation
import Testing

@testable import Moolah

/// Regression coverage for the
/// `AccountCashFlows.flowAmounts(for:)` extraction in
/// `AccountPerformanceCalculator.extractFlows`. Lives in its own
/// file because `AccountPerformanceCalculatorTests` was already at
/// the SwiftLint type-body-length limit.
@Suite("AccountPerformanceCalculator extractFlows refactor")
struct ExtractFlowsRefactorTests {
  let aud = Instrument.AUD

  /// Locks in the per-leg `CashFlow` summation across the
  /// `AccountCashFlows.flowAmounts(for:)` refactor. Modified Dietz /
  /// IRR weighting is invariant to leg order within the same date,
  /// but the `totalContributions` sum is not — a refactor that
  /// silently dropped a leg or applied the boundary-crossing rule
  /// at a different granularity would slip past the existing suite.
  @Test("extractFlows preserves per-leg contributions across a multi-leg transaction")
  func extractFlowsPreservesLegContributions() async throws {
    let accountId = UUID()
    let txn = Transaction(
      date: Date(timeIntervalSince1970: 1_700_000_000),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: 100,
          type: .openingBalance),
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: 200,
          type: .openingBalance),
      ]
    )
    let valued = [
      ValuedPosition(
        instrument: aud, quantity: 300, unitPrice: nil, costBasis: nil,
        value: InstrumentAmount(quantity: 300, instrument: aud))
    ]
    let perf = try await AccountPerformanceCalculator.compute(
      accountId: accountId,
      transactions: [txn],
      valuedPositions: valued,
      profileCurrency: aud,
      conversionService: FixedConversionService()
    )
    #expect(
      perf.totalContributions == InstrumentAmount(quantity: 300, instrument: aud)
    )
    #expect(perf.firstFlowDate == txn.date)
  }
}
