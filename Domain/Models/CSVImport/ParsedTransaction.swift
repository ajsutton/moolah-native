import Foundation

/// One leg of a parsed CSV row. `accountId` is `nil` at parse time for cash
/// legs — the profile-routing step fills it in. Position legs (e.g. brokerage
/// trades) reference their target account directly.
struct ParsedLeg: Sendable, Hashable {
  var accountId: UUID?
  var instrument: Instrument
  var quantity: Decimal
  var type: TransactionType
}

/// The ephemeral output of a `CSVParser`. Never persisted directly — the
/// pipeline converts these into `Transaction` values after profile lookup,
/// rule evaluation, and deduplication.
///
/// - Bank rows map to a single-leg value.
/// - Trades map to two legs (cash + position, different instruments).
/// - Dividends map to a single income leg on the investment account.
/// - Transfers (produced by the `markAsTransfer` rule action) have two cash
///   legs across Moolah accounts.
struct ParsedTransaction: Sendable, Hashable {
  let date: Date
  var legs: [ParsedLeg]
  let rawRow: [String]
  let rawDescription: String
  let rawAmount: Decimal
  let rawBalance: Decimal?
  let bankReference: String?
}
