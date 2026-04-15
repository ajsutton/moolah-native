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

  @State private var draft: TransactionDraft
  @State private var showDeleteConfirmation = false
  @State private var showPayeeSuggestions = false
  @State private var payeeHighlightedIndex: Int?
  @State private var showCategorySuggestions = false
  @State private var categoryHighlightedIndex: Int?
  @State private var categoryJustSelected = false
  @FocusState private var focusedField: Field?

  private enum Field: Hashable {
    case payee
    case amount
  }

  /// The leg relevant for display/editing in the current context.
  private var relevantLeg: TransactionLeg? {
    if let viewingAccountId {
      return transaction.legs.first { $0.accountId == viewingAccountId }
    }
    if transaction.isTransfer {
      return transaction.legs.first { $0.quantity < 0 }
    }
    return transaction.legs.first
  }

  private var isEditable: Bool {
    transaction.isSimple
  }

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

    var initialDraft = TransactionDraft(from: transaction, viewingAccountId: viewingAccountId)
    if let catId = transaction.categoryId, let cat = categories.by(id: catId) {
      initialDraft.categoryText = categories.path(for: cat)
    }
    _draft = State(initialValue: initialDraft)
  }

  private var isNewTransaction: Bool {
    // Detect if this is a new transaction by checking if it has default values
    (relevantLeg?.amount.isZero ?? true) && (transaction.payee?.isEmpty ?? true)
  }

  private var sortedAccounts: [Account] {
    accounts.ordered.sorted { a, b in
      // Current accounts (bank, asset, creditCard) before investment accounts
      if a.type.isCurrent != b.type.isCurrent {
        return a.type.isCurrent
      }
      return a.position < b.position
    }
  }

  var body: some View {
    formContent
      .formStyle(.grouped)
      .overlayPreferenceValue(PayeeFieldAnchorKey.self) { anchor in
        payeeOverlay(anchor: anchor)
      }
      .overlayPreferenceValue(CategoryPickerAnchorKey.self) { anchor in
        categoryOverlay(anchor: anchor)
      }
      .navigationTitle("Transaction Details")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .onAppear {
        if isNewTransaction {
          focusedField = .payee
        }
      }
      .onChange(of: draft) { _, _ in debouncedSave() }
      .confirmationDialog(
        "Delete Transaction",
        isPresented: $showDeleteConfirmation,
        titleVisibility: .visible
      ) {
        Button("Delete", role: .destructive) {
          onDelete(transaction.id)
        }
        .keyboardShortcut(.delete, modifiers: [])
      } message: {
        Text("Are you sure you want to delete this transaction? This cannot be undone.")
      }
  }

  private var formContent: some View {
    Form {
      typeSection.disabled(!isEditable)
      detailsSection.disabled(!isEditable)
      accountSection.disabled(!isEditable)
      categorySection.disabled(!isEditable)
      if showRecurrence {
        recurrenceSection.disabled(!isEditable)
      }
      notesSection
      if isScheduled {
        paySection
      }
      deleteSection
    }
  }

  @ViewBuilder
  private func payeeOverlay(anchor: Anchor<CGRect>?) -> some View {
    if showPayeeSuggestions, !draft.payee.isEmpty,
      !transactionStore.payeeSuggestions.isEmpty, let anchor
    {
      GeometryReader { proxy in
        let rect = proxy[anchor]
        PayeeSuggestionDropdown(
          suggestions: transactionStore.payeeSuggestions,
          searchText: draft.payee,
          highlightedIndex: $payeeHighlightedIndex,
          onSelect: { selected in
            showPayeeSuggestions = false
            payeeHighlightedIndex = nil
            draft.payee = selected
            transactionStore.clearPayeeSuggestions()
            autofillFromPayee(selected)
          }
        )
        .frame(width: rect.width)
        .offset(x: rect.minX, y: rect.maxY + 4)
      }
    }
  }

  // MARK: - Sections

  private var typeSection: some View {
    Section {
      if transaction.type == .openingBalance {
        // Opening balance transactions cannot be edited
        LabeledContent("Type") {
          Text(TransactionType.openingBalance.displayName)
            .foregroundStyle(.secondary)
        }
      } else {
        Picker("Type", selection: $draft.type) {
          ForEach(TransactionType.userSelectableTypes, id: \.self) { t in
            Text(t.displayName).tag(t)
          }
        }
        .onChange(of: draft.type) { oldValue, newValue in
          if newValue == .transfer && draft.toAccountId == nil {
            // Set first available account (excluding current account) as default
            draft.toAccountId = sortedAccounts.first { $0.id != draft.accountId }?.id
          }
        }
      }
    }
  }

  private var detailsSection: some View {
    Section {
      PayeeAutocompleteField(
        text: $draft.payee,
        highlightedIndex: $payeeHighlightedIndex,
        suggestionCount: payeeVisibleSuggestionCount,
        onTextChange: { newValue in
          showPayeeSuggestions = !newValue.isEmpty
          transactionStore.fetchPayeeSuggestions(prefix: newValue)
        },
        onAcceptHighlighted: acceptHighlightedPayee
      )
      .focused($focusedField, equals: .payee)

      HStack {
        TextField("Amount", text: $draft.amountText)
          .multilineTextAlignment(.trailing)
          #if os(iOS)
            .keyboardType(.decimalPad)
          #endif
        Text(relevantLeg?.instrument.id ?? "").foregroundStyle(.secondary)
      }

      DatePicker("Date", selection: $draft.date, displayedComponents: .date)
    }
  }

  private var accountSection: some View {
    Section {
      Picker("Account", selection: $draft.accountId) {
        Text("None").tag(UUID?.none)
        ForEach(sortedAccounts) { account in
          Text(account.name).tag(UUID?.some(account.id))
        }
      }

      if draft.type == .transfer {
        Picker("To Account", selection: $draft.toAccountId) {
          Text("Select...").tag(UUID?.none)
          ForEach(sortedAccounts.filter { $0.id != draft.accountId && !$0.isHidden }) { account in
            Text(account.name).tag(UUID?.some(account.id))
          }
        }
      }
    }
  }

  @FocusState private var categoryFieldFocused: Bool

  private var categorySection: some View {
    Section {
      CategoryAutocompleteField(
        text: $draft.categoryText,
        highlightedIndex: $categoryHighlightedIndex,
        suggestionCount: categoryVisibleSuggestionCount,
        onTextChange: { _ in
          if categoryJustSelected {
            categoryJustSelected = false
          } else {
            showCategorySuggestions = true
          }
        },
        onAcceptHighlighted: acceptHighlightedCategory
      )
      .focused($categoryFieldFocused)
      .onChange(of: categoryFieldFocused) { _, focused in
        if !focused {
          // Revert to the valid category path when focus leaves
          categoryJustSelected = true
          showCategorySuggestions = false
          categoryHighlightedIndex = nil
          if let id = draft.categoryId, let cat = categories.by(id: id) {
            draft.categoryText = categories.path(for: cat)
          } else {
            draft.categoryText = ""
            draft.categoryId = nil
          }
        }
      }

      Picker("Earmark", selection: $draft.earmarkId) {
        Text("None").tag(UUID?.none)
        ForEach(earmarks.ordered.filter { !$0.isHidden }) { earmark in
          Text(earmark.name).tag(UUID?.some(earmark.id))
        }
      }
      #if os(macOS)
        .pickerStyle(.menu)
      #endif
    }
  }

  private var recurrenceSection: some View {
    Section("Recurrence") {
      Toggle("Repeat", isOn: $draft.isRepeating)
        .onChange(of: draft.isRepeating) { _, newValue in
          if newValue {
            // Default to monthly recurrence when enabled
            if draft.recurPeriod == nil || draft.recurPeriod == .once {
              draft.recurPeriod = .month
            }
          } else {
            draft.recurPeriod = nil
          }
        }

      if draft.isRepeating {
        HStack {
          Text("Every")
          Spacer()
          TextField("", value: $draft.recurEvery, format: .number)
            #if os(iOS)
              .keyboardType(.numberPad)
            #endif
            .multilineTextAlignment(.trailing)
            .frame(minWidth: 40, idealWidth: 60, maxWidth: 80)
            .accessibilityLabel("Recurrence interval")
        }

        Picker(
          "Period",
          selection: Binding(
            get: { draft.recurPeriod ?? .month },
            set: { draft.recurPeriod = $0 }
          )
        ) {
          ForEach(RecurPeriod.allCases.filter { $0 != .once }, id: \.self) { period in
            Text(draft.recurEvery == 1 ? period.displayName : period.pluralDisplayName)
              .tag(period)
          }
        }
        .accessibilityLabel("Recurrence period")
        #if os(macOS)
          .pickerStyle(.menu)
        #endif
      }
    }
  }

  private var notesSection: some View {
    Section {
      VStack(alignment: .leading) {
        Text("Notes")
        TextEditor(text: $draft.notes)
          .frame(minHeight: 60, maxHeight: 120)
          .scrollContentBackground(.hidden)
          .padding()
          .background(.background)
          .overlay(
            RoundedRectangle(cornerRadius: 4)
              .stroke(.separator, lineWidth: 1)
          )
      }
    }
  }

  @State private var isPaying = false

  private var isScheduled: Bool {
    showRecurrence && transaction.recurPeriod != nil
  }

  private var paySection: some View {
    Section {
      Button {
        Task {
          isPaying = true
          let result = await transactionStore.payScheduledTransaction(transaction)
          isPaying = false
          switch result {
          case .paid(let updated):
            if let updated {
              onUpdate(updated)
            } else {
              onDelete(transaction.id)
            }
          case .deleted:
            onDelete(transaction.id)
          case .failed:
            break
          }
        }
      } label: {
        HStack {
          Spacer()
          if isPaying {
            ProgressView()
              .controlSize(.small)
          } else {
            Text("Pay Now")
          }
          Spacer()
        }
      }
      .disabled(isPaying)
    }
  }

  private var deleteSection: some View {
    Section {
      Button(role: .destructive) {
        showDeleteConfirmation = true
      } label: {
        Text("Delete")
          .frame(maxWidth: .infinity)
      }
    }
  }

  // MARK: - Actions

  private var payeeVisibleSuggestions: [String] {
    guard showPayeeSuggestions, !draft.payee.isEmpty else { return [] }
    return transactionStore.payeeSuggestions
      .filter { $0.localizedCaseInsensitiveCompare(draft.payee) != .orderedSame }
      .prefix(8).map { $0 }
  }

  private var payeeVisibleSuggestionCount: Int {
    payeeVisibleSuggestions.count
  }

  private func acceptHighlightedPayee() {
    guard let index = payeeHighlightedIndex, index < payeeVisibleSuggestions.count else { return }
    let selected = payeeVisibleSuggestions[index]
    showPayeeSuggestions = false
    payeeHighlightedIndex = nil
    draft.payee = selected
    transactionStore.clearPayeeSuggestions()
    autofillFromPayee(selected)
  }

  private func autofillFromPayee(_ selectedPayee: String) {
    Task {
      guard let match = await transactionStore.fetchTransactionForAutofill(payee: selectedPayee)
      else { return }
      // Auto-fill fields that are still at defaults
      if draft.parsedQuantity == nil || draft.parsedQuantity == 0 {
        let matchLeg =
          draft.accountId.flatMap { acctId in
            match.legs.first { $0.accountId == acctId }
          } ?? match.legs.first
        if let matchLeg {
          draft.amountText = abs(matchLeg.quantity).formatted(
            .number.precision(.fractionLength(matchLeg.instrument.decimals)))
        }
      }
      if draft.categoryId == nil, let matchCategoryId = match.categoryId {
        draft.categoryId = matchCategoryId
        if let cat = categories.by(id: matchCategoryId) {
          categoryJustSelected = true
          draft.categoryText = categories.path(for: cat)
        }
      }
      if draft.type == .expense && match.type != .expense {
        draft.type = match.type
      }
      if match.isSimple, draft.type == .transfer, draft.toAccountId == nil {
        let matchTransferLeg = match.legs.first(where: { $0.accountId != draft.accountId })
        draft.toAccountId = matchTransferLeg?.accountId
      }
    }
  }

  // MARK: - Category Suggestions

  private var categoryVisibleSuggestions: [CategorySuggestion] {
    guard showCategorySuggestions else { return [] }
    let allEntries = categories.flattenedByPath()
    let filtered: [Categories.FlatEntry]
    if draft.categoryText.trimmingCharacters(in: .whitespaces).isEmpty {
      filtered = allEntries
    } else {
      filtered = allEntries.filter { matchesCategorySearch($0.path, query: draft.categoryText) }
    }
    return filtered.prefix(8).map { CategorySuggestion(id: $0.category.id, path: $0.path) }
  }

  private var categoryVisibleSuggestionCount: Int {
    categoryVisibleSuggestions.count
  }

  private func acceptHighlightedCategory() {
    guard let index = categoryHighlightedIndex, index < categoryVisibleSuggestions.count else {
      return
    }
    let selected = categoryVisibleSuggestions[index]
    categoryJustSelected = true
    draft.categoryId = selected.id
    draft.categoryText = selected.path
    showCategorySuggestions = false
    categoryHighlightedIndex = nil
  }

  @ViewBuilder
  private func categoryOverlay(anchor: Anchor<CGRect>?) -> some View {
    if showCategorySuggestions, !categoryVisibleSuggestions.isEmpty, let anchor {
      GeometryReader { proxy in
        let rect = proxy[anchor]
        CategorySuggestionDropdown(
          suggestions: categoryVisibleSuggestions,
          searchText: draft.categoryText,
          highlightedIndex: $categoryHighlightedIndex,
          onSelect: { selected in
            categoryJustSelected = true
            draft.categoryId = selected.id
            draft.categoryText = selected.path
            showCategorySuggestions = false
            categoryHighlightedIndex = nil
          }
        )
        .frame(width: rect.width)
        .offset(x: rect.minX, y: rect.maxY + 4)
      }
    }
  }

  private func debouncedSave() {
    transactionStore.debouncedSave { [self] in
      saveIfValid()
    }
  }

  private func saveIfValid() {
    let fromInstrument = relevantLeg?.instrument ?? transaction.legs.first?.instrument ?? .AUD
    let toInstrument: Instrument?
    if draft.type == .transfer, let toAcctId = draft.toAccountId {
      let toAccountInstrument =
        accounts.by(id: toAcctId)?.positions.first?.instrument
        ?? accounts.by(id: toAcctId)?.balance.instrument
      toInstrument = toAccountInstrument
    } else {
      toInstrument = nil
    }
    guard
      let updated = draft.toTransaction(
        id: transaction.id,
        fromInstrument: fromInstrument,
        toInstrument: toInstrument)
    else { return }
    onUpdate(updated)
  }
}

#Preview {
  let accountId = UUID()
  NavigationStack {
    TransactionDetailView(
      transaction: Transaction(
        date: Date(),
        payee: "Woolworths",
        legs: [
          TransactionLeg(accountId: accountId, instrument: .AUD, quantity: -50.23, type: .expense)
        ]
      ),
      accounts: Accounts(from: [
        Account(id: accountId, name: "Checking", type: .bank),
        Account(name: "Savings", type: .bank),
      ]),
      categories: Categories(from: [
        Category(name: "Groceries"),
        Category(name: "Transport"),
      ]),
      earmarks: Earmarks(from: [
        Earmark(name: "Holiday Fund")
      ]),
      transactionStore: {
        let (backend, _) = PreviewBackend.create()
        return TransactionStore(
          repository: backend.transactions,
          conversionService: backend.conversionService,
          targetInstrument: .AUD
        )
      }(),
      viewingAccountId: accountId,
      onUpdate: { _ in },
      onDelete: { _ in }
    )
  }
}
