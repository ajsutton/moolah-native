import Foundation

/// One date-stamped, signed contribution into (or withdrawal out of) an
/// investment account, expressed in the profile's reporting currency.
///
/// `date` records when the flow occurred. `amount` is a signed monetary
/// value in the account's reporting currency, stored as `Decimal` rather
/// than `InstrumentAmount` because every flow within a given calculation
/// shares the account's reporting currency; carrying a per-flow
/// `Instrument` would be redundant. `Decimal` (not `Int` cents) is used
/// because IRR / Modified Dietz arithmetic involves fractional weighting.
///
/// **Sign convention:** positive = capital flowing *into* the account from
/// outside (deposits, opening balance), negative = capital flowing *out* to
/// outside (withdrawals). The sign must be preserved through all arithmetic;
/// callers must not `abs()` this value.
///
/// Inclusion rules for which transaction legs contribute a `CashFlow` are
/// determined by `AccountPerformanceCalculator`.
struct CashFlow {
  let date: Date
  let amount: Decimal
}

extension CashFlow: Sendable {}

extension CashFlow: Equatable {}
