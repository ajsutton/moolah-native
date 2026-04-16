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
  var isRepeating: Bool
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
    case .income, .openingBalance: return false
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

// MARK: - Computed Accessors (Simple Mode)

extension TransactionDraft {
  /// The leg the simple UI binds to for amount display/editing.
  var relevantLeg: LegDraft {
    get { legDrafts[relevantLegIndex] }
    set { legDrafts[relevantLegIndex] = newValue }
  }

  /// The counterpart leg in a simple transfer (the leg that isn't the relevant one).
  /// Nil for non-transfer simple transactions.
  var counterpartLeg: LegDraft? {
    guard legDrafts.count == 2 else { return nil }
    let otherIndex = relevantLegIndex == 0 ? 1 : 0
    return legDrafts[otherIndex]
  }

  private var counterpartLegIndex: Int? {
    guard legDrafts.count == 2 else { return nil }
    return relevantLegIndex == 0 ? 1 : 0
  }

  /// The transaction type, read from the relevant leg.
  var type: TransactionType {
    relevantLeg.type
  }

  /// The account on the relevant leg.
  var accountId: UUID? {
    get { relevantLeg.accountId }
    set { legDrafts[relevantLegIndex].accountId = newValue }
  }

  /// The display amount text from the relevant leg.
  var amountText: String {
    relevantLeg.amountText
  }

  /// The counterpart account (for simple transfers).
  var toAccountId: UUID? {
    get { counterpartLeg?.accountId }
    set {
      if let idx = counterpartLegIndex {
        legDrafts[idx].accountId = newValue
      }
    }
  }

  /// Category on the primary leg (index 0).
  var categoryId: UUID? {
    get { legDrafts[0].categoryId }
    set { legDrafts[0].categoryId = newValue }
  }

  /// Category text on the primary leg (index 0).
  var categoryText: String {
    get { legDrafts[0].categoryText }
    set { legDrafts[0].categoryText = newValue }
  }

  /// Earmark on the primary leg (index 0).
  var earmarkId: UUID? {
    get { legDrafts[0].earmarkId }
    set { legDrafts[0].earmarkId = newValue }
  }

  /// Whether the "other account" label should read "From Account" instead of "To Account".
  /// True when viewing from the counterpart's perspective (the relevant leg is not the primary leg).
  var showFromAccount: Bool {
    relevantLegIndex != 0
  }
}

// MARK: - Convenience Initialisers

extension TransactionDraft {
  /// Create a draft pre-populated from an existing transaction (for editing).
  init(from transaction: Transaction, viewingAccountId: UUID? = nil) {
    // Build legDrafts from all legs, applying the negation rule for display
    let drafts = transaction.legs.map { leg in
      LegDraft(
        type: leg.type,
        accountId: leg.accountId,
        amountText: Self.displayText(
          quantity: leg.quantity, type: leg.type, decimals: leg.instrument.decimals),
        categoryId: leg.categoryId,
        categoryText: "",
        earmarkId: leg.earmarkId
      )
    }

    let isCustom = !transaction.isSimple

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
      viewingAccountId: viewingAccountId
    )
  }

  /// Create a blank draft for a new transaction.
  init(accountId: UUID? = nil, viewingAccountId: UUID? = nil) {
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
          categoryId: nil, categoryText: "", earmarkId: nil)
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

// MARK: - Editing Methods (Simple Mode)

extension TransactionDraft {
  /// Change the transaction type, adding/removing counterpart legs as needed.
  mutating func setType(_ newType: TransactionType, accounts: Accounts) {
    let wasTransfer = type == .transfer
    let isTransfer = newType == .transfer

    if !wasTransfer && isTransfer {
      // Adding a counterpart leg for transfer
      let currentAccountId = relevantLeg.accountId
      let defaultAccount = accounts.ordered.first { $0.id != currentAccountId }

      // Parse-negate-format the counterpart amount
      let counterpartAmount = negatedAmountText(relevantLeg.amountText)

      let counterpartLeg = LegDraft(
        type: .transfer,
        accountId: defaultAccount?.id,
        amountText: counterpartAmount,
        categoryId: nil,
        categoryText: "",
        earmarkId: nil
      )

      legDrafts[relevantLegIndex].type = .transfer
      // Insert counterpart at the other position
      if relevantLegIndex == 0 {
        legDrafts.append(counterpartLeg)
      } else {
        legDrafts.insert(counterpartLeg, at: 0)
      }
    } else if wasTransfer && !isTransfer {
      // Removing counterpart leg
      if let idx = counterpartLegIndex {
        legDrafts.remove(at: idx)
        // Adjust relevantLegIndex if needed
        if relevantLegIndex > idx {
          relevantLegIndex -= 1
        }
      }
      legDrafts[relevantLegIndex].type = newType
    } else {
      // Just changing type on existing legs (expense ↔ income)
      for i in legDrafts.indices {
        legDrafts[i].type = newType
      }
    }
  }

  /// Change the display amount on the relevant leg, mirroring to counterpart for transfers.
  mutating func setAmount(_ text: String) {
    legDrafts[relevantLegIndex].amountText = text

    // Mirror to counterpart for simple transfers
    if let idx = counterpartLegIndex {
      legDrafts[idx].amountText = negatedAmountText(text)
    }
  }

  /// Parse display text, negate, and format. Returns "" if unparseable.
  /// Preserves the decimal precision from the input text.
  private func negatedAmountText(_ text: String) -> String {
    // Use a dummy decimals value — we just need to parse and negate
    guard let value = InstrumentAmount.parseQuantity(from: text, decimals: 10) else {
      return ""
    }
    let negated = -value
    if negated == .zero {
      return "0"
    }
    // Preserve the number of decimal places from the input
    let decimalPlaces: Int
    if let dotIndex = text.firstIndex(of: ".") {
      decimalPlaces = text.distance(from: text.index(after: dotIndex), to: text.endIndex)
    } else {
      decimalPlaces = 0
    }
    return negated.formatted(.number.precision(.fractionLength(decimalPlaces)).grouping(.never))
  }
}

// MARK: - Mode Switching

extension TransactionDraft {
  /// Whether the current legs satisfy `isSimple` rules, allowing a switch to simple mode.
  var canSwitchToSimple: Bool {
    if legDrafts.count <= 1 { return true }
    guard legDrafts.count == 2 else { return false }
    let a = legDrafts[0]
    let b = legDrafts[1]
    guard a.type == b.type && a.type == .transfer else { return false }
    guard b.categoryId == nil && b.earmarkId == nil else { return false }
    // Simple transfers require both legs to have accounts
    guard a.accountId != nil && b.accountId != nil else { return false }
    guard a.accountId != b.accountId else { return false }
    // Check amounts negate: parse both and compare
    guard let aVal = InstrumentAmount.parseQuantity(from: a.amountText, decimals: 10),
      let bVal = InstrumentAmount.parseQuantity(from: b.amountText, decimals: 10),
      aVal == -bVal
    else { return false }
    return true
  }

  /// Switch from custom to simple mode. Only call when `canSwitchToSimple` is true.
  mutating func switchToSimple() {
    isCustom = false
    repinRelevantLeg()
  }
}

// MARK: - Validation

extension TransactionDraft {
  /// Whether the draft represents a valid, saveable transaction.
  var isValid: Bool {
    guard !legDrafts.isEmpty else { return false }
    for leg in legDrafts {
      // Each leg must have either an account or an earmark (or both)
      guard leg.accountId != nil || leg.earmarkId != nil else { return false }
      guard !leg.amountText.isEmpty,
        InstrumentAmount.parseQuantity(from: leg.amountText, decimals: 10) != nil
      else { return false }
    }
    if isRepeating {
      guard recurPeriod != nil, recurEvery >= 1 else { return false }
    }
    return true
  }
}

// MARK: - Conversion

extension TransactionDraft {
  /// Build a `Transaction` from the draft, looking up instruments from `accounts`.
  /// Returns nil when the draft is not valid.
  func toTransaction(id: UUID, accounts: Accounts, earmarks: Earmarks = Earmarks(from: []))
    -> Transaction?
  {
    guard isValid else { return nil }

    var legs: [TransactionLeg] = []
    for legDraft in legDrafts {
      let instrument: Instrument
      if let acctId = legDraft.accountId, let account = accounts.by(id: acctId) {
        instrument = account.balance.instrument
      } else if let emId = legDraft.earmarkId, let earmark = earmarks.by(id: emId) {
        instrument = earmark.balance.instrument
      } else {
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
      recurPeriod: isRepeating ? recurPeriod : nil,
      recurEvery: isRepeating ? recurEvery : nil,
      legs: legs
    )
  }
}

// MARK: - Autofill

extension TransactionDraft {
  /// Replace this draft with data from a matching transaction, preserving the current date.
  /// Category text is populated from the categories collection.
  mutating func applyAutofill(from match: Transaction, categories: Categories) {
    let preservedDate = self.date
    let preservedViewingAccountId = self.viewingAccountId

    // Build a fresh draft from the match
    var newDraft = TransactionDraft(from: match, viewingAccountId: preservedViewingAccountId)
    newDraft.date = preservedDate

    // Populate category text for all legs
    for i in newDraft.legDrafts.indices {
      if let catId = newDraft.legDrafts[i].categoryId,
        let cat = categories.by(id: catId)
      {
        newDraft.legDrafts[i].categoryText = categories.path(for: cat)
      }
    }

    self = newDraft
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
  /// Append a blank leg for custom mode editing.
  mutating func addLeg(defaultAccountId: UUID? = nil) {
    legDrafts.append(
      LegDraft(
        type: .expense, accountId: defaultAccountId, amountText: "0",
        categoryId: nil, categoryText: "", earmarkId: nil
      ))
  }

  /// Remove a leg at the given index.
  mutating func removeLeg(at index: Int) {
    legDrafts.remove(at: index)
  }
}
