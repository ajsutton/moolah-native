import Foundation

/// Shared per-leg cash-flow classifier used by both
/// `AccountPerformanceCalculator` (the tile pass) and
/// `PositionsHistoryBuilder` (the chart pass). Centralising the
/// boundary-crossing predicate here means both consumers cannot
/// silently diverge on edge cases such as opening-balance legs or
/// cross-currency conversion dates.
///
/// Caseless `enum` (CODE_GUIDE.md §5 — pure namespace).
enum AccountCashFlows {
  /// Returns the host-currency contribution amount for every leg in
  /// `transaction` that belongs to `accountId` and counts as a flow.
  ///
  /// A leg counts iff `leg.type == .openingBalance` OR `transaction`
  /// touches at least one other non-nil `accountId`. The
  /// boundary-crossing predicate is evaluated once per transaction
  /// inside this helper so callers cannot duplicate or diverge from
  /// the rule.
  ///
  /// Returns one `Decimal` per qualifying leg (in `hostCurrency`) in
  /// the order legs appear on `transaction`. Empty when no leg
  /// qualifies.
  ///
  /// Throws on the *first* conversion failure rather than returning
  /// a partial list. Throwing puts the policy choice at the call
  /// site (`AccountPerformanceCalculator` aborts the whole
  /// `compute(...)`, `PositionsHistoryBuilder` sets
  /// `state.contributions = nil` for the rest of the build), which
  /// is clearer than a sentinel return shape with two failure modes.
  ///
  /// `nonisolated` so `@concurrent` callers
  /// (`PositionsHistoryBuilder.build`) do not hop to the main actor
  /// per transaction; default-isolation callers
  /// (`AccountPerformanceCalculator.extractFlows`) are unaffected
  /// because `nonisolated` is callable from any context.
  nonisolated static func flowAmounts(
    for transaction: Transaction,
    accountId: UUID,
    hostCurrency: Instrument,
    service: any InstrumentConversionService
  ) async throws -> [Decimal] {
    let crossesBoundary = !Set(transaction.legs.compactMap(\.accountId))
      .subtracting([accountId])
      .isEmpty

    var amounts: [Decimal] = []
    for leg in transaction.legs where leg.accountId == accountId {
      guard leg.type == .openingBalance || crossesBoundary else { continue }

      let amount: Decimal
      if leg.instrument == hostCurrency {
        amount = leg.quantity
      } else {
        amount = try await service.convert(
          leg.quantity,
          from: leg.instrument,
          to: hostCurrency,
          on: transaction.date
        )
      }
      try Task.checkCancellation()
      amounts.append(amount)
    }
    return amounts
  }
}
