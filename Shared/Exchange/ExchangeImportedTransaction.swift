import Foundation

/// One imported exchange transaction in provider-neutral form. Phase 4 maps
/// these into `Transaction`/`TransactionLeg` candidates.
struct ExchangeImportedTransaction: Sendable, Hashable {
  let externalId: String
  let occurredAt: Date
  let category: String  // TRADE | TRADEFEE | DEPOSIT | WITHDRAW | AWARD
  let direction: ExchangeDirection
  let assetSymbol: String?
  let amount: Decimal
  let isFiat: Bool
  let orderId: String?
}
