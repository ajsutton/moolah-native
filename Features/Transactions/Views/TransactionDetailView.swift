import SwiftUI

struct TransactionDetailView: View {
  let transaction: Transaction
  let accounts: Accounts
  let categories: Categories
  let earmarks: Earmarks
  let transactionStore: TransactionStore
  let showRecurrence: Bool
  let viewingAccountId: UUID?
  let supportsComplexTransactions: Bool
  let onUpdate: (Transaction) -> Void
  let onDelete: (UUID) -> Void

  @State private var draft: TransactionDraft
  @State private var showDeleteConfirmation = false
  @State private var showPayeeSuggestions = false
  @State private var payeeHighlightedIndex: Int?
  @State private var showCategorySuggestions = false
  @State private var categoryHighlightedIndex: Int?
  @State private var categoryJustSelected = false
  @State private var legPendingDeletion: Int?
  @State private var legCategoryJustSelected: [Int: Bool] = [:]
  @FocusState private var focusedField: Field?

  private enum Field: Hashable {
    case payee
    case amount
    case legAmount(Int)
  }

  private enum TransactionMode: Hashable {
    case income, expense, transfer, custom

    var displayName: String {
      switch self {
      case .income: return "Income"
      case .expense: return "Expense"
      case .transfer: return "Transfer"
      case .custom: return "Custom"
      }
    }
  }

  private var availableModes: [TransactionMode] {
    supportsComplexTransactions
      ? [.income, .expense, .transfer, .custom]
      : [.income, .expense, .transfer]
  }

  private var modeBinding: Binding<TransactionMode> {
    Binding(
      get: {
        if draft.isCustom { return .custom }
        switch draft.type {
        case .income: return .income
        case .expense: return .expense
        case .transfer: return .transfer
        case .openingBalance: return .expense
        }
      },
      set: { newMode in
        switch newMode {
        case .custom:
          draft.isCustom = true
        case .income:
          draft.isCustom = false
          draft.type = .income
        case .expense:
          draft.isCustom = false
          draft.type = .expense
        case .transfer:
          draft.isCustom = false
          draft.type = .transfer
        }
      }
    )
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
    transaction.isSimple || draft.isCustom
  }

  init(
    transaction: Transaction,
    accounts: Accounts,
    categories: Categories,
    earmarks: Earmarks,
    transactionStore: TransactionStore,
    showRecurrence: Bool = false,
    viewingAccountId: UUID? = nil,
    supportsComplexTransactions: Bool = false,
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
    self.supportsComplexTransactions = supportsComplexTransactions
    self.onUpdate = onUpdate
    self.onDelete = onDelete

    var initialDraft = TransactionDraft(from: transaction, viewingAccountId: viewingAccountId)
    if let catId = transaction.legs.first(where: { $0.categoryId != nil })?.categoryId,
      let cat = categories.by(id: catId)
    {
      initialDraft.categoryText = categories.path(for: cat)
    }
    _draft = State(initialValue: initialDraft)
  }

  private var isNewTransaction: Bool {
    if draft.isCustom {
      let allLegsEmpty = draft.legDrafts.allSatisfy { $0.amountText.isEmpty }
      return allLegsEmpty && (transaction.payee?.isEmpty ?? true)
    }
    return (relevantLeg?.amount.isZero ?? true) && (transaction.payee?.isEmpty ?? true)
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
            draft.legDrafts.remove(at: index)
            legPendingDeletion = nil
          }
        }
      } message: {
        Text("Are you sure you want to delete this sub-transaction?")
      }
  }

  private var formContent: some View {
    Form {
      typeSection.disabled(!isEditable)
      if draft.isCustom {
        customDetailsSection
        ForEach(draft.legDrafts.indices, id: \.self) { index in
          subTransactionSection(index: index)
        }
        addSubTransactionSection
        if showRecurrence {
          recurrenceSection
        }
        notesSection
      } else {
        detailsSection.disabled(!isEditable)
        accountSection.disabled(!isEditable)
        categorySection.disabled(!isEditable)
        if showRecurrence {
          recurrenceSection.disabled(!isEditable)
        }
        notesSection
      }
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
      if transaction.legs.contains(where: { $0.type == .openingBalance }) {
        // Opening balance transactions cannot be edited
        LabeledContent("Type") {
          Text(TransactionType.openingBalance.displayName)
            .foregroundStyle(.secondary)
        }
      } else if !transaction.isSimple {
        // Already-complex transactions show read-only type
        LabeledContent("Type") {
          Text("Custom")
            .foregroundStyle(.secondary)
        }
        .accessibilityHint(
          "This transaction has custom sub-transactions and cannot be changed to a simpler type.")
      } else {
        Picker("Type", selection: modeBinding) {
          ForEach(availableModes, id: \.self) { mode in
            Text(mode.displayName).tag(mode)
          }
        }
        .accessibilityLabel("Transaction type")
        #if os(iOS)
          .pickerStyle(.segmented)
        #endif
        .onChange(of: draft.type) { oldValue, newValue in
          if newValue == .transfer && draft.toAccountId == nil {
            // Set first available account (excluding current account) as default
            draft.toAccountId = sortedAccounts.first { $0.id != draft.accountId }?.id
          }
        }
        .onChange(of: draft.toAccountId) { _, newToAccountId in
          // Auto-promote to custom mode when transferring between different currencies
          if draft.type == .transfer && !draft.isCustom {
            let fromInstrument = draft.accountId.flatMap { accounts.by(id: $0) }?.balance.instrument
            let toInstrument = newToAccountId.flatMap { accounts.by(id: $0) }?.balance.instrument
            if let fromInstrument, let toInstrument, fromInstrument != toInstrument {
              draft.isCustom = true
            }
          }
        }
        .onChange(of: draft.isCustom) { oldValue, newValue in
          if newValue && !oldValue {
            // Switching to custom: build legDrafts from current simple fields
            if draft.type == .transfer {
              // Transfer: create two legs
              let fromLeg = TransactionDraft.LegDraft(
                type: .transfer,
                accountId: draft.accountId,
                amountText: draft.amountText,
                isOutflow: true,
                categoryId: draft.categoryId,
                categoryText: draft.categoryText,
                earmarkId: draft.earmarkId
              )
              let toLeg = TransactionDraft.LegDraft(
                type: .transfer,
                accountId: draft.toAccountId,
                amountText: draft.amountText,
                isOutflow: false,
                categoryId: nil,
                categoryText: "",
                earmarkId: nil
              )
              draft.legDrafts = [fromLeg, toLeg]
            } else {
              // Non-transfer: create one leg
              let isOutflow = draft.type == .expense
              let leg = TransactionDraft.LegDraft(
                type: draft.type,
                accountId: draft.accountId,
                amountText: draft.amountText,
                isOutflow: isOutflow,
                categoryId: draft.categoryId,
                categoryText: draft.categoryText,
                earmarkId: draft.earmarkId
              )
              draft.legDrafts = [leg]
            }
          } else if !newValue && oldValue {
            // Switching to simple: populate simple fields from first legDraft
            if let firstLeg = draft.legDrafts.first {
              draft.type = firstLeg.type
              draft.accountId = firstLeg.accountId
              draft.amountText = firstLeg.amountText
              draft.categoryId = firstLeg.categoryId
              draft.categoryText = firstLeg.categoryText
              draft.earmarkId = firstLeg.earmarkId
              // For two-leg transfers: map second leg to toAccountId
              if draft.legDrafts.count >= 2 {
                draft.toAccountId = draft.legDrafts[1].accountId
              }
            }
            draft.legDrafts = []
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

  private var customDetailsSection: some View {
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

      DatePicker("Date", selection: $draft.date, displayedComponents: .date)
    }
  }

  @ViewBuilder
  private func subTransactionSection(index: Int) -> some View {
    Section {
      Picker("Type", selection: $draft.legDrafts[index].type) {
        Text(TransactionType.income.displayName).tag(TransactionType.income)
        Text(TransactionType.expense.displayName).tag(TransactionType.expense)
        Text(TransactionType.transfer.displayName).tag(TransactionType.transfer)
      }

      if draft.legDrafts[index].type == .transfer {
        Picker("Direction", selection: $draft.legDrafts[index].isOutflow) {
          Text("Outflow").tag(true)
          Text("Inflow").tag(false)
        }
      }

      Picker("Account", selection: $draft.legDrafts[index].accountId) {
        Text("None").tag(UUID?.none)
        ForEach(sortedAccounts) { account in
          Text(account.name).tag(UUID?.some(account.id))
        }
      }

      HStack {
        TextField("Amount", text: $draft.legDrafts[index].amountText)
          .multilineTextAlignment(.trailing)
          .monospacedDigit()
          #if os(iOS)
            .keyboardType(.decimalPad)
          #endif
          .focused($focusedField, equals: .legAmount(index))
        Text(
          draft.legDrafts[index].accountId
            .flatMap { accounts.by(id: $0) }?
            .balance.instrument.id ?? ""
        )
        .foregroundStyle(.secondary)
        .monospacedDigit()
      }

      Picker("Category", selection: $draft.legDrafts[index].categoryId) {
        Text("None").tag(UUID?.none)
        ForEach(categories.flattenedByPath(), id: \.category.id) { entry in
          Text(entry.path).tag(UUID?.some(entry.category.id))
        }
      }
      #if os(macOS)
        .pickerStyle(.menu)
      #endif

      Picker("Earmark", selection: $draft.legDrafts[index].earmarkId) {
        Text("None").tag(UUID?.none)
        ForEach(earmarks.ordered.filter { !$0.isHidden }) { earmark in
          Text(earmark.name).tag(UUID?.some(earmark.id))
        }
      }
      #if os(macOS)
        .pickerStyle(.menu)
      #endif

      if draft.legDrafts.count > 1 {
        Button(role: .destructive) {
          legPendingDeletion = index
        } label: {
          Text("Delete Sub-transaction")
            .frame(maxWidth: .infinity)
        }
        .accessibilityLabel("Delete sub-transaction")
      }
    }
    .accessibilityLabel("Sub-transaction \(index + 1) of \(draft.legDrafts.count)")
  }

  private var addSubTransactionSection: some View {
    Section {
      Button("Add Sub-transaction") {
        draft.legDrafts.append(
          TransactionDraft.LegDraft(
            type: .expense,
            accountId: sortedAccounts.first?.id,
            amountText: "",
            isOutflow: true,
            categoryId: nil,
            categoryText: "",
            earmarkId: nil
          )
        )
      }
      .accessibilityLabel("Add sub-transaction")
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
      draft.applyAutofill(
        from: match,
        categories: categories,
        supportsComplexTransactions: supportsComplexTransactions
      )
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
    if draft.isCustom {
      guard let updated = draft.toTransaction(id: transaction.id, accounts: accounts)
      else { return }
      onUpdate(updated)
    } else {
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
      supportsComplexTransactions: true,
      onUpdate: { _ in },
      onDelete: { _ in }
    )
  }
}

#Preview("Custom Transaction") {
  let accountId1 = UUID()
  let accountId2 = UUID()
  NavigationStack {
    TransactionDetailView(
      transaction: Transaction(
        date: Date(),
        payee: "Split Purchase",
        legs: [
          TransactionLeg(
            accountId: accountId1, instrument: .AUD, quantity: -30.00, type: .expense,
            categoryId: nil),
          TransactionLeg(
            accountId: accountId2, instrument: .AUD, quantity: -20.00, type: .expense,
            categoryId: nil),
        ]
      ),
      accounts: Accounts(from: [
        Account(id: accountId1, name: "Checking", type: .bank),
        Account(id: accountId2, name: "Credit Card", type: .creditCard),
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
      supportsComplexTransactions: true,
      onUpdate: { _ in },
      onDelete: { _ in }
    )
  }
}
