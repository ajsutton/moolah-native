import Foundation

/// A value type that captures transaction form state and encapsulates the
/// validation and conversion logic shared between `TransactionDetailView`
/// and `TransactionFormView`. All amount-signing and field-clearing rules
/// live here so they can be unit-tested without a UI host.
struct TransactionDraft: Sendable {
  var type: TransactionType
  var payee: String
  var amountText: String
  var date: Date
  var accountId: UUID?
  var toAccountId: UUID?
  var categoryId: UUID?
  var earmarkId: UUID?
  var notes: String
  var isRepeating: Bool
  var recurPeriod: RecurPeriod?
  var recurEvery: Int

  // MARK: - Parsing & Validation

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
    guard let qty = parsedQuantity, isValid else { return nil }

    let signedQty: Decimal = (type == .expense || type == .transfer) ? -abs(qty) : abs(qty)

    guard let acctId = accountId else { return nil }
    var legs: [TransactionLeg] = []
    legs.append(
      TransactionLeg(
        accountId: acctId, instrument: instrument, quantity: signedQty,
        type: type == .transfer ? .transfer : type,
        categoryId: type == .transfer ? nil : categoryId,
        earmarkId: type == .transfer ? nil : earmarkId
      ))
    if type == .transfer, let toAcctId = toAccountId {
      legs.append(
        TransactionLeg(
          accountId: toAcctId, instrument: instrument, quantity: -signedQty, type: .transfer
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
  init(from transaction: Transaction) {
    let primaryLeg = transaction.legs.first
    let transferLeg =
      transaction.legs.count > 1
      ? transaction.legs.first(where: { $0.accountId != primaryLeg?.accountId })
      : nil
    self.init(
      type: primaryLeg?.type == .transfer ? .transfer : (primaryLeg?.type ?? .expense),
      payee: transaction.payee ?? "",
      amountText: primaryLeg.map {
        abs($0.quantity).formatted(.number.precision(.fractionLength(2)))
      } ?? "",
      date: transaction.date,
      accountId: primaryLeg?.accountId,
      toAccountId: transferLeg?.accountId,
      categoryId: primaryLeg?.categoryId,
      earmarkId: primaryLeg?.earmarkId,
      notes: transaction.notes ?? "",
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
      isRepeating: false,
      recurPeriod: nil,
      recurEvery: 1
    )
  }
}
