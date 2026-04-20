import Foundation

/// One leg of a parsed CSV row. `accountId` is `nil` at parse time for cash
/// legs — the profile-routing step fills it in. Position legs (e.g. brokerage
/// trades) reference their target account directly.
///
/// `isInstrumentPlaceholder` signals that the leg's `instrument` is a
/// pipeline-placeholder (typically `.AUD`) that the orchestrator should
/// rewrite to the routed account's actual instrument before persisting.
/// Parsers set this to `true` on cash legs and `false` on position legs
/// (e.g. stock tickers) where the instrument is the real one already.
struct ParsedLeg: Sendable, Hashable {
  var accountId: UUID?
  var instrument: Instrument
  var quantity: Decimal
  var type: TransactionType
  var isInstrumentPlaceholder: Bool

  init(
    accountId: UUID?,
    instrument: Instrument,
    quantity: Decimal,
    type: TransactionType,
    isInstrumentPlaceholder: Bool = false
  ) {
    self.accountId = accountId
    self.instrument = instrument
    self.quantity = quantity
    self.type = type
    self.isInstrumentPlaceholder = isInstrumentPlaceholder
  }
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
