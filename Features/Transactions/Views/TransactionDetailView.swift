// swift-format wraps `TransactionLeg(...)` calls with one argument per line
// inside the previews; SwiftLint's multiline_arguments rule (which expects
// "all on one line OR one per line including the first") then trips on the
// formatter's chosen style. The formatter wins per project policy
// (.swift-format is the layout source of truth), so suppress the lint here.
// swiftlint:disable multiline_arguments

import SwiftUI

// Common fiat instruments available to leg-instrument resolution when the
// instrument registry has not yet loaded (e.g. on first render). Registered
// stocks/crypto are supplied by `knownInstruments` loaded via `.task`.
private let commonFiatInstruments: [Instrument] = [
  "AUD", "CAD", "CHF", "CNY", "EUR", "GBP", "HKD", "INR", "JPY", "KRW",
  "MXN", "NOK", "NZD", "SEK", "SGD", "USD", "ZAR",
].map { Instrument.fiat(code: $0) }

struct TransactionDetailView: View {
  let transaction: Transaction
  let accounts: Accounts
  let categories: Categories
  let earmarks: Earmarks
  let transactionStore: TransactionStore
  let showRecurrence: Bool
  let viewingAccountId: UUID?
  let onUpdate: (Transaction) -> Void
  let onDelete: (UUID) -> Void

  @Environment(ProfileSession.self) private var session

  @State private var draft: TransactionDraft
  @State private var knownInstruments: [Instrument] = []
  @State private var showDeleteConfirmation = false
  @State private var payeeState = PayeeAutocompleteState()
  @State private var categoryState = CategoryAutocompleteState()
  @State private var legCategoryStates: [Int: CategoryAutocompleteState] = [:]
  @State private var legPendingDeletion: Int?
  /// Snapshot of whether the transaction was a blank/new draft at open
  /// time (empty payee + all-zero legs). Captured once at init so that
  /// `autofillFromPayee` only copies fields from a matched transaction
  /// when the user is filling in a fresh transaction — never when they
  /// are editing an existing one. Without this guard, selecting a payee
  /// from the dropdown while editing a $5,000 transfer would clobber the
  /// amount, type, and category.
  @State private var openedAsNewTransaction: Bool
  @FocusState private var focusedField: TransactionDetailFocus?

  init(
    transaction: Transaction,
    accounts: Accounts,
    categories: Categories,
    earmarks: Earmarks,
    transactionStore: TransactionStore,
    showRecurrence: Bool = false,
    viewingAccountId: UUID? = nil,
    onUpdate: @escaping (Transaction) -> Void,
    onDelete: @escaping (UUID) -> Void
  ) {
    self.transaction = transaction
    self.accounts = accounts
    self.categories = categories
    self.earmarks = earmarks
    self.transactionStore = transactionStore
    self.showRecurrence = showRecurrence
    self.viewingAccountId = viewingAccountId
    self.onUpdate = onUpdate
    self.onDelete = onDelete

    var initialDraft = TransactionDraft(
      from: transaction, viewingAccountId: viewingAccountId, accounts: accounts)
    for i in initialDraft.legDrafts.indices {
      if let catId = initialDraft.legDrafts[i].categoryId,
        let cat = categories.by(id: catId)
      {
        initialDraft.legDrafts[i].categoryText = categories.path(for: cat)
      }
    }
    _draft = State(initialValue: initialDraft)

    let payeeEmpty = (transaction.payee?.isEmpty ?? true)
    let allLegsZero = transaction.legs.allSatisfy { $0.quantity == .zero }
    _openedAsNewTransaction = State(initialValue: payeeEmpty && allLegsZero)
  }

  var body: some View {
    formContent
      .formStyle(.grouped)
      .overlayPreferenceValue(PayeeFieldAnchorKey.self) { anchor in
        PayeeAutocompleteOverlay(
          anchor: anchor,
          payee: $draft.payee,
          state: $payeeState,
          suggestionSource: transactionStore.payeeSuggestionSource,
          onAutofill: autofillFromPayee
        )
      }
      .overlayPreferenceValue(CategoryPickerAnchorKey.self) { anchor in
        TransactionDetailCategoryOverlay(
          anchor: anchor,
          draft: $draft,
          categories: categories,
          state: $categoryState
        )
      }
      .overlayPreferenceValue(LegCategoryPickerAnchorKey.self) { anchors in
        TransactionDetailLegCategoryOverlay(
          anchors: anchors,
          draft: $draft,
          categories: categories,
          legStates: $legCategoryStates
        )
      }
      .navigationTitle("Transaction Details")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      #if os(macOS)
        // `defaultFocus` alone does not pull first-responder into the inspector
        // when focus currently sits outside its region; `.task(id:)` runs
        // after the view is in the window hierarchy and imperatively claims
        // focus on the expected field. The list view cooperates by blurring
        // the `.searchable` toolbar field when the inspector opens, so the
        // responder chain's fallback doesn't steal our assignment.
        .defaultFocus($focusedField, isSimpleEarmarkOnly ? .amount : .payee)
        .task(id: transaction.id) {
          focusedField = isSimpleEarmarkOnly ? .amount : .payee
        }
      #endif
      .onChange(of: draft) { _, _ in debouncedSave() }
      .task {
        knownInstruments = (try? await session.instrumentRegistry?.all()) ?? []
      }
      .confirmationDialog(
        "Delete Transaction",
        isPresented: $showDeleteConfirmation,
        titleVisibility: .visible
      ) {
        Button("Delete", role: .destructive) {
          onDelete(transaction.id)
        }
      } message: {
        Text("Are you sure you want to delete this transaction? This cannot be undone.")
      }
      .confirmationDialog(
        "Delete Sub-transaction",
        isPresented: Binding(
          get: { legPendingDeletion != nil },
          set: { if !$0 { legPendingDeletion = nil } }
        ),
        titleVisibility: .visible
      ) {
        Button("Delete", role: .destructive) {
          if let index = legPendingDeletion {
            draft.removeLeg(at: index)
            shiftLegCategoryStates(after: index)
            legPendingDeletion = nil
          }
        }
      } message: {
        Text("Are you sure you want to delete this sub-transaction?")
      }
  }
}

// MARK: - Form Content & Section Composition

extension TransactionDetailView {
  private var formContent: some View {
    Form {
      modeAwareSections
      if isScheduled {
        TransactionDetailPaySection(
          transaction: transaction,
          transactionStore: transactionStore,
          onUpdate: onUpdate,
          onDelete: onDelete
        )
      }
      TransactionDetailDeleteSection(onRequestDelete: { showDeleteConfirmation = true })
    }
  }

  @ViewBuilder private var modeAwareSections: some View {
    if isSimpleEarmarkOnly {
      earmarkOnlyContent
    } else if draft.isCustom {
      customModeContent
    } else {
      simpleModeContent
    }
  }

  @ViewBuilder private var earmarkOnlyContent: some View {
    TransactionDetailEarmarkOnlySection(
      draft: $draft, earmarks: earmarks, amountBinding: amountBinding)
    if showRecurrence {
      TransactionDetailRecurrenceSection(draft: $draft)
    }
    TransactionDetailNotesSection(notes: $draft.notes)
  }

  @ViewBuilder private var simpleModeContent: some View {
    modeSection.disabled(!isEditable)
    TransactionDetailDetailsSection(
      draft: $draft,
      amountBinding: amountBinding,
      relevantInstrument: relevantInstrument,
      isCrossCurrency: isCrossCurrency,
      suggestionSource: transactionStore.payeeSuggestionSource,
      payeeState: $payeeState,
      onAutofill: autofillFromPayee,
      focusedField: $focusedField
    )
    .disabled(!isEditable)
    TransactionDetailAccountSection(
      draft: $draft,
      accounts: accounts,
      sortedAccounts: sortedAccounts,
      relevantInstrument: relevantInstrument,
      counterpartInstrument: counterpartInstrument,
      counterpartAmountBinding: counterpartAmountBinding,
      isCrossCurrency: isCrossCurrency,
      focusedField: $focusedField
    )
    .disabled(!isEditable)
    TransactionDetailCategorySection(
      draft: $draft, categories: categories, earmarks: earmarks, state: $categoryState
    )
    .disabled(!isEditable)
    if showRecurrence {
      TransactionDetailRecurrenceSection(draft: $draft).disabled(!isEditable)
    }
    TransactionDetailNotesSection(notes: $draft.notes)
  }

  @ViewBuilder private var customModeContent: some View {
    modeSection.disabled(!isEditable)
    TransactionDetailCustomDetailsSection(
      draft: $draft,
      suggestionSource: transactionStore.payeeSuggestionSource,
      payeeState: $payeeState,
      onAutofill: autofillFromPayee,
      focusedField: $focusedField
    )
    ForEach(draft.legDrafts.indices, id: \.self) { index in
      TransactionDetailLegRow(
        index: index,
        totalLegCount: draft.legDrafts.count,
        draft: $draft,
        accounts: accounts,
        categories: categories,
        earmarks: earmarks,
        knownInstruments: knownInstruments,
        sortedAccounts: sortedAccounts,
        categoryState: legCategoryStateBinding(for: index),
        focusedField: $focusedField,
        onRequestDelete: { legPendingDeletion = index }
      )
    }
    TransactionDetailAddLegSection(draft: $draft, sortedAccounts: sortedAccounts)
    if showRecurrence {
      TransactionDetailRecurrenceSection(draft: $draft)
    }
    TransactionDetailNotesSection(notes: $draft.notes)
  }

  private var modeSection: some View {
    TransactionDetailModeSection(
      transaction: transaction,
      draft: $draft,
      accounts: accounts
    )
  }

  private func legCategoryStateBinding(
    for index: Int
  ) -> Binding<CategoryAutocompleteState> {
    Binding(
      get: { legCategoryStates[index] ?? CategoryAutocompleteState() },
      set: { legCategoryStates[index] = $0 }
    )
  }

  /// Re-key the per-leg dropdown state dict after the leg at `removedIndex`
  /// is removed. Without this, an open dropdown on a higher-indexed leg
  /// would re-bind to the *new* leg at that shifted index — e.g.
  /// deleting leg 0 with three legs would leak leg 1's open-dropdown
  /// flag onto the new leg 0.
  private func shiftLegCategoryStates(after removedIndex: Int) {
    var shifted: [Int: CategoryAutocompleteState] = [:]
    for (key, state) in legCategoryStates where key != removedIndex {
      shifted[key < removedIndex ? key : key - 1] = state
    }
    legCategoryStates = shifted
  }
}

// MARK: - Computed Helpers

extension TransactionDetailView {
  private var sortedAccounts: [Account] {
    accounts.ordered.sorted { lhs, rhs in
      if lhs.type.isCurrent != rhs.type.isCurrent {
        return lhs.type.isCurrent
      }
      return lhs.position < rhs.position
    }
  }

  private var isEditable: Bool { transaction.isSimple || draft.isCustom }

  /// Whether the current draft is a simple earmark-only transaction.
  private var isSimpleEarmarkOnly: Bool {
    !draft.isCustom && draft.relevantLeg.isEarmarkOnly
  }

  /// The instrument for the relevant leg's account (for displaying currency symbol).
  private var relevantInstrument: Instrument? {
    draft.legDrafts[draft.relevantLegIndex].accountId
      .flatMap { accounts.by(id: $0) }?
      .instrument
  }

  /// Whether the current draft is a cross-currency simple transfer.
  private var isCrossCurrency: Bool {
    !draft.isCustom && draft.type == .transfer && draft.isCrossCurrencyTransfer(accounts: accounts)
  }

  /// The instrument for the counterpart leg's account.
  private var counterpartInstrument: Instrument? {
    draft.counterpartLeg?.accountId
      .flatMap { accounts.by(id: $0) }?
      .instrument
  }

  private var counterpartAmountBinding: Binding<String> {
    Binding(
      get: { draft.counterpartLeg?.amountText ?? "" },
      set: { draft.setCounterpartAmount($0) }
    )
  }

  private var amountBinding: Binding<String> {
    Binding(
      get: { draft.amountText },
      set: { draft.setAmount($0, accounts: accounts) }
    )
  }

  private var isScheduled: Bool {
    showRecurrence && transaction.recurPeriod != nil
  }
}

// MARK: - Actions

extension TransactionDetailView {
  private func autofillFromPayee(_ selectedPayee: String) {
    // Only auto-copy amount/type/category from a past transaction when
    // the user is filling in a fresh draft. Editing an existing
    // transaction's payee must never rewrite other fields — do not
    // remove this guard without replacing the invariant it enforces.
    guard openedAsNewTransaction else { return }
    Task {
      guard
        let match = await transactionStore.payeeSuggestionSource.fetchTransactionForAutofill(
          payee: selectedPayee)
      else { return }
      draft.applyAutofill(from: match, categories: categories, accounts: accounts)
    }
  }

  private func debouncedSave() {
    transactionStore.debouncedSave { [self] in
      saveIfValid()
    }
  }

  private func saveIfValid() {
    let allKnownInstruments = knownInstruments + commonFiatInstruments
    guard
      let updated = draft.toTransaction(
        id: transaction.id, accounts: accounts, earmarks: earmarks,
        availableInstruments: allKnownInstruments)
    else { return }
    onUpdate(updated)
  }
}
