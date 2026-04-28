// swiftlint:disable multiline_arguments

import Foundation

/// A value type that captures transaction form state and encapsulates
/// validation, editing, and conversion logic. The view binds to this;
/// all business logic lives here so it can be unit-tested without a UI host.
///
/// Data is always stored in `legDrafts` — even simple transactions.
/// `isCustom` controls which UI renders, not which data is active.
struct TransactionDraft: Sendable, Equatable {
  // MARK: - Shared Fields

  var payee: String
  var date: Date
  var notes: String
  var isRepeating: Bool {
    didSet {
      if isRepeating {
        if recurPeriod == nil || recurPeriod == .once {
          recurPeriod = .month
        }
      } else {
        recurPeriod = wasScheduledAtInit ? .once : nil
      }
    }
  }
  var recurPeriod: RecurPeriod?
  var recurEvery: Int

  /// Presentation mode: controls whether the UI shows simple or custom editor.
  var isCustom: Bool

  /// Always populated — even simple 1-leg transactions store their data here.
  var legDrafts: [LegDraft]

  /// Index of the leg the simple UI edits. Only meaningful when `isCustom == false`.
  /// Pinned at init or when switching from custom to simple mode.
  var relevantLegIndex: Int

  /// The account perspective for this editing session. Set at init, does not change.
  let viewingAccountId: UUID?

  /// Whether the transaction this draft was initialised from was scheduled
  /// (i.e. `recurPeriod != nil`). Once a transaction is scheduled, toggling
  /// off "Repeat" demotes it to `.once` (scheduled, non-recurring) rather
  /// than clearing recurrence entirely — the inspector doesn't provide a
  /// way to convert a scheduled transaction back to a regular one.
  var wasScheduledAtInit: Bool = false

  // MARK: - LegDraft

  /// A draft for a single leg in a transaction.
  struct LegDraft: Sendable, Equatable {
    var type: TransactionType
    var accountId: UUID?
    /// The display value — negated for expense/transfer types.
    /// This is exactly what the user sees in the text field.
    var amountText: String
    var categoryId: UUID?
    var categoryText: String
    var earmarkId: UUID?
    /// Optional instrument override for custom mode (e.g. cross-currency legs).
    var instrumentId: String?

    init(
      type: TransactionType,
      accountId: UUID?,
      amountText: String,
      categoryId: UUID?,
      categoryText: String,
      earmarkId: UUID?,
      instrumentId: String? = nil
    ) {
      self.type = type
      self.accountId = accountId
      self.amountText = amountText
      self.categoryId = categoryId
      self.categoryText = categoryText
      self.earmarkId = earmarkId
      self.instrumentId = instrumentId
    }

    /// True when this leg represents an earmark-only entry (no account).
    var isEarmarkOnly: Bool {
      accountId == nil && earmarkId != nil
    }
  }

  // MARK: - Negation Helpers

  /// Whether a leg type uses negated display (expense, transfer → negate; income, openingBalance → as-is).
  static func displaysNegated(_ type: TransactionType) -> Bool {
    switch type {
    case .expense, .transfer: return true
    case .income, .openingBalance, .trade: return false
    }
  }

  /// Convert a leg quantity to display text using the negation rule.
  static func displayText(quantity: Decimal, type: TransactionType, decimals: Int) -> String {
    let displayValue = displaysNegated(type) ? -quantity : quantity
    if displayValue == .zero {
      return "0"
    }
    return displayValue.formatted(.number.precision(.fractionLength(decimals)).grouping(.never))
  }

  /// Parse display text back to a signed quantity using the negation rule.
  /// Returns nil if the text can't be parsed.
  static func parseDisplayText(_ text: String, type: TransactionType, decimals: Int) -> Decimal? {
    guard let parsed = InstrumentAmount.parseQuantity(from: text, decimals: decimals) else {
      return nil
    }
    return displaysNegated(type) ? -parsed : parsed
  }
}

// Computed accessors, editing methods, and mode-switching helpers for simple mode
// live in `TransactionDraft+SimpleMode.swift`.

// MARK: - Convenience Initialisers

extension TransactionDraft {
  /// Create a draft pre-populated from an existing transaction (for editing).
  init(
    from transaction: Transaction,
    viewingAccountId: UUID? = nil,
    accounts: Accounts = Accounts(from: [])
  ) {
    // Always populate instrumentId so the draft is self-describing and round-trips
    // preserve each leg's instrument — including cases where a leg's instrument
    // differs from its account's instrument (e.g. a cross-currency trade booked
    // against a single investment account).
    let drafts = transaction.legs.map { leg in
      LegDraft(
        type: leg.type,
        accountId: leg.accountId,
        amountText: Self.displayText(
          quantity: leg.quantity, type: leg.type, decimals: leg.instrument.decimals),
        categoryId: leg.categoryId,
        categoryText: "",
        earmarkId: leg.earmarkId,
        instrumentId: leg.instrument.id
      )
    }

    let isCrossCurrency =
      transaction.isSimpleCrossCurrencyTransfer
      && transaction.legs.allSatisfy { leg in
        guard let acctId = leg.accountId,
          let account = accounts.by(id: acctId)
        else { return false }
        return leg.instrument == account.instrument
      }
    let isCustom = !(transaction.isSimple || isCrossCurrency)

    // Pin relevantLegIndex for simple transactions
    let relevantIndex: Int
    if isCustom {
      relevantIndex = 0  // Unused in custom mode
    } else {
      relevantIndex = Self.pinRelevantLeg(
        legs: transaction.legs, viewingAccountId: viewingAccountId)
    }

    self.init(
      payee: transaction.payee ?? "",
      date: transaction.date,
      notes: transaction.notes ?? "",
      isRepeating: transaction.recurPeriod != nil && transaction.recurPeriod != .once,
      recurPeriod: transaction.recurPeriod,
      recurEvery: transaction.recurEvery ?? 1,
      isCustom: isCustom,
      legDrafts: drafts,
      relevantLegIndex: relevantIndex,
      viewingAccountId: viewingAccountId,
      wasScheduledAtInit: transaction.recurPeriod != nil
    )
  }

  /// Create a blank earmark-only draft for a new earmark transaction.
  init(earmarkId: UUID, instrumentId: String? = nil, viewingAccountId: UUID? = nil) {
    self.init(
      payee: "",
      date: Date(),
      notes: "",
      isRepeating: false,
      recurPeriod: nil,
      recurEvery: 1,
      isCustom: false,
      legDrafts: [
        LegDraft(
          type: .income, accountId: nil, amountText: "0",
          categoryId: nil, categoryText: "", earmarkId: earmarkId,
          instrumentId: instrumentId)
      ],
      relevantLegIndex: 0,
      viewingAccountId: viewingAccountId
    )
  }

  /// Create a blank draft for a new transaction.
  init(accountId: UUID? = nil, instrumentId: String? = nil, viewingAccountId: UUID? = nil) {
    self.init(
      payee: "",
      date: Date(),
      notes: "",
      isRepeating: false,
      recurPeriod: nil,
      recurEvery: 1,
      isCustom: false,
      legDrafts: [
        LegDraft(
          type: .expense, accountId: accountId, amountText: "0",
          categoryId: nil, categoryText: "", earmarkId: nil,
          instrumentId: instrumentId)
      ],
      relevantLegIndex: 0,
      viewingAccountId: viewingAccountId
    )
  }

  /// Determine the relevant leg index for a simple transaction.
  static func pinRelevantLeg(legs: [TransactionLeg], viewingAccountId: UUID?) -> Int {
    if let viewingAccountId {
      if let index = legs.firstIndex(where: { $0.accountId == viewingAccountId }) {
        return index
      }
    }
    // No context or no match: always index 0
    return 0
  }

  /// Re-pin the relevant leg from current legDrafts (used when switching to simple mode).
  mutating func repinRelevantLeg() {
    if let viewingAccountId {
      if let index = legDrafts.firstIndex(where: { $0.accountId == viewingAccountId }) {
        relevantLegIndex = index
        return
      }
    }
    relevantLegIndex = 0
  }
}

// MARK: - Validation

extension TransactionDraft {
  /// Whether the draft represents a valid, saveable transaction.
  var isValid: Bool {
    guard !legDrafts.isEmpty else { return false }
    for leg in legDrafts {
      // .trade legs must have an account (no earmark-only fallback per design §3.2).
      // All other types require either an account or an earmark (or both).
      if leg.type == .trade {
        guard leg.accountId != nil else { return false }
      } else {
        guard leg.accountId != nil || leg.earmarkId != nil else { return false }
      }
      guard !leg.amountText.isEmpty,
        InstrumentAmount.parseQuantity(from: leg.amountText, decimals: 10) != nil
      else { return false }
    }
    if isRepeating {
      guard let period = recurPeriod, period != .once, recurEvery >= 1 else { return false }
    }
    return true
  }
}

// MARK: - Conversion

extension TransactionDraft {
  /// Build a `Transaction` from the draft. Each leg's `instrumentId` must resolve
  /// in `availableInstruments`; `accounts` and `earmarks` are unused for instrument
  /// lookup (each leg is self-describing) but remain as parameters for future use.
  /// Returns nil when the draft is invalid or an instrument can't be resolved.
  func toTransaction(
    id: UUID,
    accounts: Accounts = Accounts(from: []),
    earmarks: Earmarks = Earmarks(from: []),
    availableInstruments: [Instrument] = []
  ) -> Transaction? {
    guard isValid else { return nil }

    var legs: [TransactionLeg] = []
    for legDraft in legDrafts {
      guard let overrideId = legDraft.instrumentId,
        let instrument = availableInstruments.first(where: { $0.id == overrideId })
      else {
        return nil
      }

      guard
        let quantity = Self.parseDisplayText(
          legDraft.amountText, type: legDraft.type, decimals: instrument.decimals)
      else { return nil }

      legs.append(
        TransactionLeg(
          accountId: legDraft.accountId,
          instrument: instrument,
          quantity: quantity,
          type: legDraft.type,
          categoryId: legDraft.categoryId,
          earmarkId: legDraft.earmarkId
        ))
    }

    return Transaction(
      id: id,
      date: date,
      payee: payee.isEmpty ? nil : payee,
      notes: notes.isEmpty ? nil : notes,
      recurPeriod: recurPeriod,
      recurEvery: recurPeriod == nil ? nil : recurEvery,
      legs: legs
    )
  }
}

// MARK: - Earmark-Only Invariants

extension TransactionDraft {
  /// Enforce earmark-only invariants on a leg: force income type, clear category.
  /// No-op if the leg is not earmark-only.
  mutating func enforceEarmarkOnlyInvariants(at index: Int) {
    guard legDrafts[index].isEarmarkOnly else { return }
    legDrafts[index].type = .income
    legDrafts[index].categoryId = nil
    legDrafts[index].categoryText = ""
  }
}

// MARK: - Custom Mode Operations

extension TransactionDraft {
  /// Append a blank leg for custom mode editing. Callers should pass the default
  /// account's instrument so the leg is self-describing from the start.
  mutating func addLeg(defaultAccountId: UUID? = nil, instrumentId: String? = nil) {
    legDrafts.append(
      LegDraft(
        type: .expense, accountId: defaultAccountId, amountText: "0",
        categoryId: nil, categoryText: "", earmarkId: nil,
        instrumentId: instrumentId
      ))
  }

  /// Remove a leg at the given index.
  mutating func removeLeg(at index: Int) {
    legDrafts.remove(at: index)
  }
}
