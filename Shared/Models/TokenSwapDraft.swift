import Foundation

/// Draft for a token swap transaction (e.g., ETH -> UNI on a DEX).
/// Produces multi-leg transactions: two transfer legs for the swap,
/// optional expense leg for gas fee.
struct TokenSwapDraft: Sendable {
  let accountId: UUID

  var sourceInstrument: Instrument?
  var sourceQuantity: Decimal = 0
  var destinationInstrument: Instrument?
  var destinationQuantity: Decimal = 0

  // Optional gas fee
  var gasFeeInstrument: Instrument?
  var gasFeeQuantity: Decimal = 0
  var gasFeeCategoryId: UUID?

  var date: Date = Date()
  var notes: String?

  var isValid: Bool {
    guard sourceInstrument != nil, destinationInstrument != nil else { return false }
    guard sourceQuantity > 0, destinationQuantity > 0 else { return false }
    return true
  }

  func buildLegs() -> [TransactionLeg] {
    guard let source = sourceInstrument, let dest = destinationInstrument else { return [] }

    var legs: [TransactionLeg] = []

    // Outflow: source instrument leaves the account
    legs.append(
      TransactionLeg(
        accountId: accountId,
        instrument: source,
        quantity: -sourceQuantity,
        type: .transfer
      ))

    // Inflow: destination instrument enters the account
    legs.append(
      TransactionLeg(
        accountId: accountId,
        instrument: dest,
        quantity: destinationQuantity,
        type: .transfer
      ))

    // Optional gas fee
    if let feeInstrument = gasFeeInstrument, gasFeeQuantity > 0 {
      legs.append(
        TransactionLeg(
          accountId: accountId,
          instrument: feeInstrument,
          quantity: -gasFeeQuantity,
          type: .expense,
          categoryId: gasFeeCategoryId
        ))
    }

    return legs
  }

  func buildTransaction() -> Transaction {
    Transaction(
      id: UUID(),
      date: date,
      payee: nil,
      notes: notes,
      legs: buildLegs()
    )
  }
}
