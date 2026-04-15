import Foundation

/// Captures trade form state and converts it into a multi-leg Transaction.
/// Parallel to TransactionDraft for regular transactions.
struct TradeDraft: Sendable {
  var accountId: UUID
  var date: Date = Date()

  // Sold side (outflow)
  var soldInstrument: Instrument?
  var soldQuantityText: String = ""

  // Bought side (inflow)
  var boughtInstrument: Instrument?
  var boughtQuantityText: String = ""

  // Optional fee
  var feeInstrument: Instrument?
  var feeAmountText: String = ""
  var feeCategoryId: UUID?

  var notes: String = ""

  // MARK: - Parsing

  /// Parse a quantity text into a positive Decimal, stripping commas.
  private static func parseQuantity(_ text: String) -> Decimal? {
    let cleaned = text.replacingOccurrences(of: ",", with: "")
    guard !cleaned.isEmpty, let value = Decimal(string: cleaned), value > 0 else { return nil }
    return value
  }

  var parsedSoldQuantity: Decimal? { Self.parseQuantity(soldQuantityText) }
  var parsedBoughtQuantity: Decimal? { Self.parseQuantity(boughtQuantityText) }
  var parsedFeeAmount: Decimal? { Self.parseQuantity(feeAmountText) }

  // MARK: - Validation

  var isValid: Bool {
    guard soldInstrument != nil,
      boughtInstrument != nil,
      parsedSoldQuantity != nil,
      parsedBoughtQuantity != nil
    else { return false }
    return true
  }

  // MARK: - Conversion

  /// Build a multi-leg Transaction from the trade draft.
  /// Returns nil if the draft is not valid.
  func toTransaction(id: UUID) -> Transaction? {
    guard let soldInst = soldInstrument,
      let boughtInst = boughtInstrument,
      let soldQty = parsedSoldQuantity,
      let boughtQty = parsedBoughtQuantity
    else { return nil }

    var legs: [TransactionLeg] = []

    // Leg 0: sold side (outflow — negative quantity)
    legs.append(
      TransactionLeg(
        accountId: accountId,
        instrument: soldInst,
        quantity: -soldQty,
        type: .transfer
      ))

    // Leg 1: bought side (inflow — positive quantity)
    legs.append(
      TransactionLeg(
        accountId: accountId,
        instrument: boughtInst,
        quantity: boughtQty,
        type: .transfer
      ))

    // Leg 2: optional fee (expense, negative quantity)
    if let feeAmount = parsedFeeAmount, let feeInst = feeInstrument ?? soldInstrument {
      legs.append(
        TransactionLeg(
          accountId: accountId,
          instrument: feeInst,
          quantity: -feeAmount,
          type: .expense,
          categoryId: feeCategoryId
        ))
    }

    let payee = generatePayee(
      soldInst: soldInst,
      boughtInst: boughtInst,
      soldQty: soldQty,
      boughtQty: boughtQty
    )

    return Transaction(
      id: id,
      date: date,
      payee: payee,
      notes: notes.isEmpty ? nil : notes,
      legs: legs
    )
  }

  // MARK: - Payee Generation

  private func generatePayee(
    soldInst: Instrument,
    boughtInst: Instrument,
    soldQty: Decimal,
    boughtQty: Decimal
  ) -> String {
    // If selling stock for fiat: "Sell {qty} {name}"
    // If buying stock with fiat: "Buy {qty} {name}"
    // If stock-to-stock: "Trade {sold} for {bought}"
    if soldInst.kind == .stock && boughtInst.kind == .fiatCurrency {
      return "Sell \(soldQty.formattedQuantity) \(soldInst.name)"
    } else if soldInst.kind == .fiatCurrency && boughtInst.kind == .stock {
      return "Buy \(boughtQty.formattedQuantity) \(boughtInst.name)"
    } else {
      return "Trade \(soldInst.name) for \(boughtInst.name)"
    }
  }
}

// MARK: - Decimal Formatting Helper

extension Decimal {
  /// Format a quantity for display, removing trailing zeros.
  var formattedQuantity: String {
    let formatter = NumberFormatter()
    formatter.minimumFractionDigits = 0
    formatter.maximumFractionDigits = 8
    formatter.numberStyle = .decimal
    formatter.groupingSeparator = ""
    return formatter.string(from: self as NSDecimalNumber) ?? "\(self)"
  }
}
