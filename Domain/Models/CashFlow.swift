import Foundation

/// One date-stamped, signed contribution into (or withdrawal out of) an
/// investment account, expressed in the profile's reporting currency.
///
/// **Sign convention:** positive = capital flowing *into* the account from
/// outside (deposits, opening balance), negative = capital flowing *out* to
/// outside (withdrawals). Per CLAUDE.md the sign is semantically meaningful;
/// callers must never `abs()` the amount.
///
/// Inclusion rules for which transaction legs become `CashFlow`s live with
/// the calculator (see §2 of `plans/2026-04-29-investment-pl-design.md`).
struct CashFlow: Sendable, Hashable {
  let date: Date
  let amount: Decimal
}
