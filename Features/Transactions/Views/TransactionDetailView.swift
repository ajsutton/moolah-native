import SwiftUI

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

  @Environment(ProfileSession.self) private var session: ProfileSession?

  // `draft` and `openedAsNewTransaction` use internal access (no `private`)
  // so that extension files in this module
  // (TransactionDetailView+Helpers.swift, TransactionDetailView+Actions.swift)
  // can reference them. SwiftLint's strict_fileprivate rule disallows
  // `fileprivate`, making internal the smallest legal cross-file scope.
  @State var draft: TransactionDraft
  @State private var showDeleteConfirmation = false
  @State private var showTransferDismissConfirmation = false
  // Module-internal so the unmerge section in
  // `TransactionDetailView+Actions.swift` can arm it. SwiftLint's
  // strict_fileprivate rule makes internal the smallest legal
  // cross-file scope.
  @State var showUnmergeConfirmation = false
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
  @State var openedAsNewTransaction: Bool
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
      .confirmationDialog(
        "Dismiss Transfer Suggestion",
        isPresented: $showTransferDismissConfirmation,
        titleVisibility: .visible
      ) {
        Button("Dismiss Suggestion", role: .destructive) {
          Task { await transactionStore.dismissSuggestedTransfer(transaction) }
        }
      } message: {
        Text(
          "These transactions stay separate and will not be suggested as a "
            + "transfer again. This decision is synced across your devices.")
      }
      .confirmationDialog(
        "Split Transfer into Separate Transactions",
        isPresented: $showUnmergeConfirmation,
        titleVisibility: .visible
      ) {
        Button("Split Back into Separate Transactions", role: .destructive) {
          Task { await transactionStore.unmerge(transaction) }
        }
      } message: {
        Text(
          "The two original transactions are restored and stay separate. "
            + "This decision is synced across your devices.")
      }
  }
}

// MARK: - Form Content & Section Composition

extension TransactionDetailView {
  private var formContent: some View {
    Form {
      modeAwareSections
      // Banner offering to collapse this transaction and its detected
      // counterpart into one merged transfer. Hides itself when the
      // transaction carries no transfer suggestion.
      TransactionDetailTransferSuggestion(
        transaction: transaction,
        transactionStore: transactionStore,
        showDismissConfirmation: $showTransferDismissConfirmation
      )
      // Per-leg block-explorer links for any leg with an externalId
      // (on-chain tx hash). Skipped when no leg qualifies — the section
      // hides itself rather than rendering an empty header.
      TransactionDetailBlockExplorerSection(transaction: transaction)
      // Per-leg on-chain counterparty rows for any leg with a non-nil
      // `counterpartyAddress`. Skipped when no leg qualifies. Renders
      // truncated addresses with copy-to-clipboard buttons; deliberately
      // not a clickable link (an arbitrary on-chain address shouldn't
      // look authoritative).
      TransactionDetailCounterpartySection(transaction: transaction)
      if isScheduled {
        TransactionDetailPaySection(
          transaction: transaction,
          transactionStore: transactionStore,
          onUpdate: onUpdate,
          onDelete: onDelete
        )
      }
      unmergeSection
      TransactionDetailDeleteSection(onRequestDelete: { showDeleteConfirmation = true })
    }
  }

  @ViewBuilder private var modeAwareSections: some View {
    if isSimpleEarmarkOnly {
      earmarkOnlyContent
    } else if isTradeMode {
      tradeModeContent
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

  /// True when the draft is not in custom mode and has at least one `.trade` leg.
  private var isTradeMode: Bool {
    !draft.isCustom && draft.legDrafts.contains { $0.type == .trade }
  }

  @ViewBuilder private var tradeModeContent: some View {
    modeSection.disabled(!isEditable)
    // Payee + date sit at the top alongside the type picker, mirroring the
    // simple income / expense / transfer layout so the form reads
    // consistently across modes.
    TransactionDetailCustomDetailsSection(
      draft: $draft,
      suggestionSource: transactionStore.payeeSuggestionSource,
      editingTransactionId: transaction.id,
      payeeState: $payeeState,
      onAutofill: autofillFromPayee,
      focusedField: $focusedField
    )
    .disabled(!isEditable)

    TransactionDetailTradeSection(
      draft: $draft,
      accounts: accounts,
      focusedField: $focusedField
    )
    .disabled(!isEditable)

    ForEach(Array(draft.feeIndices.enumerated()), id: \.element) { ordinal, legIndex in
      TransactionDetailFeeSection(
        legIndex: legIndex,
        displayNumber: ordinal + 1,
        draft: $draft,
        accounts: accounts,
        categories: categories,
        earmarks: earmarks,
        categoryState: legCategoryStateBinding(for: legIndex),
        focusedField: $focusedField,
        onRequestRemove: { draft.removeFee(at: legIndex) }
      )
    }

    Section {
      Button {
        let defaultInstrument =
          draft.legDrafts.first?.accountId
          .flatMap { accounts.by(id: $0) }?.instrument ?? Instrument.AUD
        draft.appendFee(defaultInstrument: defaultInstrument)
      } label: {
        Label("Add Fee", systemImage: "plus")
          .frame(maxWidth: .infinity)
      }
      .accessibilityIdentifier(UITestIdentifiers.Detail.tradeAddFeeButton)
    }

    if showRecurrence {
      TransactionDetailRecurrenceSection(draft: $draft).disabled(!isEditable)
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
      editingTransactionId: transaction.id,
      payeeState: $payeeState,
      onAutofill: autofillFromPayee,
      focusedField: $focusedField
    )
    .disabled(!isEditable)
    TransactionDetailAccountSection(
      draft: $draft,
      accounts: accounts,
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
      editingTransactionId: transaction.id,
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
        categoryState: legCategoryStateBinding(for: index),
        focusedField: $focusedField,
        onRequestDelete: { legPendingDeletion = index }
      )
    }
    TransactionDetailAddLegSection(draft: $draft, accounts: accounts)
    if showRecurrence {
      TransactionDetailRecurrenceSection(draft: $draft)
    }
    TransactionDetailNotesSection(notes: $draft.notes)
  }

  private var modeSection: some View {
    TransactionDetailModeSection(
      transaction: transaction,
      draft: $draft,
      accounts: accounts,
      focusedField: $focusedField
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

// Computed helpers (isEditable, isSimpleEarmarkOnly, instruments,
// bindings, isScheduled) live in TransactionDetailView+Helpers.swift.
// Actions (autofillFromPayee, debouncedSave, saveIfValid) and the
// unmergeSection view builder live in TransactionDetailView+Actions.swift.
