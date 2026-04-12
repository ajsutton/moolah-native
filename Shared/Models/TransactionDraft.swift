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

  /// Parse the user-entered amount text into positive cents, or `nil` if the
  /// text is unparseable or zero.
  var parsedCents: Int? {
    guard let cents = MonetaryAmount.parseCents(from: amountText),
      cents > 0
    else { return nil }
    return cents
  }

  /// Whether the draft represents a valid, saveable transaction.
  var isValid: Bool {
    guard parsedCents != nil else { return false }
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
  /// `currency` that should stamp the resulting `MonetaryAmount`.
  func toTransaction(id: UUID, currency: Currency) -> Transaction? {
    guard let cents = parsedCents, isValid else { return nil }

    let signedCents: Int
    switch type {
    case .expense, .transfer:
      signedCents = -abs(cents)
    case .income, .openingBalance:
      signedCents = abs(cents)
    }

    return Transaction(
      id: id,
      type: type,
      date: date,
      accountId: accountId,
      toAccountId: type == .transfer ? toAccountId : nil,
      amount: MonetaryAmount(cents: signedCents, currency: currency),
      payee: payee.isEmpty ? nil : payee,
      notes: notes.isEmpty ? nil : notes,
      categoryId: categoryId,
      earmarkId: earmarkId,
      recurPeriod: isRepeating ? recurPeriod : nil,
      recurEvery: isRepeating ? recurEvery : nil
    )
  }
}

// MARK: - Convenience Initialisers

extension TransactionDraft {
  /// Create a draft pre-populated from an existing transaction (for editing).
  init(from transaction: Transaction) {
    self.init(
      type: transaction.type,
      payee: transaction.payee ?? "",
      amountText: transaction.amount.formatNoSymbol,
      date: transaction.date,
      accountId: transaction.accountId,
      toAccountId: transaction.toAccountId,
      categoryId: transaction.categoryId,
      earmarkId: transaction.earmarkId,
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
