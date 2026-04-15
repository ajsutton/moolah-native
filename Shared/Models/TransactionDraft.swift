import Foundation

/// A value type that captures transaction form state and encapsulates the
/// validation and conversion logic used by `TransactionDetailView`.
/// live here so they can be unit-tested without a UI host.
struct TransactionDraft: Sendable, Equatable {
  var type: TransactionType
  var payee: String
  var amountText: String
  var date: Date
  var accountId: UUID?
  var toAccountId: UUID?
  var categoryId: UUID?
  var earmarkId: UUID?
  var notes: String
  var categoryText: String
  var toAmountText: String
  var isRepeating: Bool
  var recurPeriod: RecurPeriod?
  var recurEvery: Int

  // MARK: - Parsing & Validation

  /// Parse the to-amount text into a positive quantity for cross-currency transfers.
  var parsedToQuantity: Decimal? {
    guard !toAmountText.isEmpty else { return nil }
    guard let qty = InstrumentAmount.parseQuantity(from: toAmountText, decimals: 2),
      qty > 0
    else { return nil }
    return qty
  }

  /// Parse the user-entered amount text into a positive quantity, or `nil` if the
  /// text is unparseable or zero.
  var parsedQuantity: Decimal? {
    guard let qty = InstrumentAmount.parseQuantity(from: amountText, decimals: 2),
      qty > 0
    else { return nil }
    return qty
  }

  /// Whether the draft represents a valid, saveable transaction.
  var isValid: Bool {
    guard parsedQuantity != nil else { return false }
    if type == .transfer {
      guard toAccountId != nil, toAccountId != accountId else { return false }
    }
    if isRepeating {
      guard recurPeriod != nil, recurEvery >= 1 else { return false }
    }
    return true
  }

  // MARK: - Conversion

  /// Build a `Transaction` from the draft's current state.
  ///
  /// Returns `nil` when the draft is not valid (see ``isValid``).
  /// The caller supplies the transaction `id` (existing or new) and the
  /// `instrument` that should stamp the resulting legs.
  func toTransaction(id: UUID, instrument: Instrument) -> Transaction? {
    toTransaction(id: id, fromInstrument: instrument, toInstrument: nil)
  }

  /// Build a `Transaction` with support for cross-currency transfers.
  ///
  /// - Parameters:
  ///   - id: Transaction ID (existing or new).
  ///   - fromInstrument: The instrument for the source account.
  ///   - toInstrument: The instrument for the destination account (transfers only).
  ///     If nil, uses `fromInstrument`.
  func toTransaction(
    id: UUID,
    fromInstrument: Instrument,
    toInstrument: Instrument?
  ) -> Transaction? {
    guard let qty = parsedQuantity, isValid else { return nil }

    let signedQty: Decimal = (type == .expense || type == .transfer) ? -abs(qty) : abs(qty)

    guard let acctId = accountId else { return nil }
    var legs: [TransactionLeg] = []
    legs.append(
      TransactionLeg(
        accountId: acctId, instrument: fromInstrument, quantity: signedQty,
        type: type == .transfer ? .transfer : type,
        categoryId: type == .transfer ? nil : categoryId,
        earmarkId: type == .transfer ? nil : earmarkId
      ))
    if type == .transfer, let toAcctId = toAccountId {
      let resolvedToInstrument = toInstrument ?? fromInstrument
      // Use toAmountText if provided, otherwise mirror the from amount
      let toQuantity: Decimal = parsedToQuantity ?? abs(qty)
      legs.append(
        TransactionLeg(
          accountId: toAcctId, instrument: resolvedToInstrument,
          quantity: toQuantity, type: .transfer
        ))
    }
    return Transaction(
      id: id, date: date, payee: payee.isEmpty ? nil : payee,
      notes: notes.isEmpty ? nil : notes,
      recurPeriod: isRepeating ? recurPeriod : nil,
      recurEvery: isRepeating ? recurEvery : nil, legs: legs)
  }
}

// MARK: - Convenience Initialisers

extension TransactionDraft {
  /// Create a draft pre-populated from an existing transaction (for editing).
  ///
  /// - Parameters:
  ///   - transaction: The transaction to populate from.
  ///   - viewingAccountId: When provided, selects the leg matching this account as the
  ///     primary leg. Useful for transfers where the "from" perspective depends on which
  ///     account the user is currently viewing.
  init(from transaction: Transaction, viewingAccountId: UUID? = nil) {
    let primaryLeg: TransactionLeg?
    if let viewingAccountId {
      primaryLeg = transaction.legs.first { $0.accountId == viewingAccountId }
    } else if transaction.isTransfer {
      primaryLeg = transaction.legs.first { $0.quantity < 0 }
    } else {
      primaryLeg = transaction.legs.first
    }
    let transferLeg = transaction.legs.first { $0.accountId != primaryLeg?.accountId }

    // For cross-currency transfers, populate the to-amount from the inflow leg
    let toAmountText: String
    if let transferLeg, primaryLeg?.instrument != transferLeg.instrument {
      toAmountText = abs(transferLeg.quantity).formatted(
        .number.precision(.fractionLength(transferLeg.instrument.decimals)))
    } else {
      toAmountText = ""
    }

    self.init(
      type: primaryLeg?.type == .transfer ? .transfer : (primaryLeg?.type ?? .expense),
      payee: transaction.payee ?? "",
      amountText: primaryLeg.map {
        abs($0.quantity).formatted(.number.precision(.fractionLength($0.instrument.decimals)))
      } ?? "",
      date: transaction.date,
      accountId: primaryLeg?.accountId,
      toAccountId: transferLeg?.accountId,
      categoryId: transaction.legs.first(where: { $0.categoryId != nil })?.categoryId,
      earmarkId: transaction.legs.first(where: { $0.earmarkId != nil })?.earmarkId,
      notes: transaction.notes ?? "",
      categoryText: "",
      toAmountText: toAmountText,
      isRepeating: transaction.recurPeriod != nil && transaction.recurPeriod != .once,
      recurPeriod: transaction.recurPeriod,
      recurEvery: transaction.recurEvery ?? 1
    )
  }

  /// Create a blank draft for a new transaction.
  init(accountId: UUID? = nil) {
    self.init(
      type: .expense,
      payee: "",
      amountText: "",
      date: Date(),
      accountId: accountId,
      toAccountId: nil,
      categoryId: nil,
      earmarkId: nil,
      notes: "",
      categoryText: "",
      toAmountText: "",
      isRepeating: false,
      recurPeriod: nil,
      recurEvery: 1
    )
  }
}
