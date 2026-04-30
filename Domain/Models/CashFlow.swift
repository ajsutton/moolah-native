import Foundation

/// One date-stamped, signed contribution into (or withdrawal out of) an
/// investment account, expressed in the profile's reporting currency.
///
/// **Sign convention:** positive = capital flowing *into* the account from
/// outside (deposits, opening balance), negative = capital flowing *out* to
/// outside (withdrawals). The sign must be preserved through all arithmetic;
/// callers must not `abs()` this value.
///
/// - Parameter date: The date of the cash flow.
/// - Parameter amount: Signed monetary amount in the account's reporting
///   currency, stored as `Decimal` rather than `InstrumentAmount` because every
///   flow within a given calculation shares the account's reporting currency;
///   carrying a per-flow `Instrument` would be redundant. Stored as `Decimal`
///   (not `Int` cents) because IRR / Modified Dietz arithmetic involves
///   fractional weighting.
///
/// Inclusion rules for which transaction legs contribute a `CashFlow` are
/// determined by `AccountPerformanceCalculator`.
struct CashFlow {
  let date: Date
  let amount: Decimal
}

extension CashFlow: Sendable {}

extension CashFlow: Hashable {}
