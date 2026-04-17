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
  let availableInstruments: [Instrument]
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
  @State private var showLegCategorySuggestions: [Int: Bool] = [:]
  @State private var legCategoryHighlightedIndex: [Int: Int?] = [:]
  @FocusState private var focusedField: Field?

  private enum Field: Hashable {
    case payee
    case amount
    case counterpartAmount
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
          if draft.isCustom { draft.switchToSimple() }
          draft.setType(.income, accounts: accounts)
        case .expense:
          if draft.isCustom { draft.switchToSimple() }
          draft.setType(.expense, accounts: accounts)
        case .transfer:
          if draft.isCustom { draft.switchToSimple() }
          draft.setType(.transfer, accounts: accounts)
        }
      }
    )
  }

  private var amountBinding: Binding<String> {
    Binding(
      get: { draft.amountText },
      set: { draft.setAmount($0, accounts: accounts) }
    )
  }

  private var isEditable: Bool {
    transaction.isSimple || draft.isCustom
  }

  /// Whether the current draft is a simple earmark-only transaction.
  private var isSimpleEarmarkOnly: Bool {
    !draft.isCustom && draft.relevantLeg.isEarmarkOnly
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
    availableInstruments: [Instrument] = CurrencyPicker.commonCurrencyCodes.map {
      Instrument.fiat(code: $0)
    },
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
    self.availableInstruments = availableInstruments
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
  }

  private var isNewTransaction: Bool {
    if draft.isCustom {
      let allLegsEmpty = draft.legDrafts.allSatisfy {
        $0.amountText.isEmpty || $0.amountText == "0"
      }
      return allLegsEmpty && (transaction.payee?.isEmpty ?? true)
    }
    return (draft.amountText == "0" || draft.amountText.isEmpty)
      && (transaction.payee?.isEmpty ?? true)
  }

  private var sortedAccounts: [Account] {
    accounts.ordered.sorted { a, b in
      if a.type.isCurrent != b.type.isCurrent {
        return a.type.isCurrent
      }
      return a.position < b.position
    }
  }

  /// Filter transfer account options, excluding the current account and hidden accounts.
  private func eligibleTransferAccounts(excluding currentAccountId: UUID?) -> [Account] {
    sortedAccounts.filter { $0.id != currentAccountId && !$0.isHidden }
  }

  /// Resolve the instrument ID for a leg, checking account first then earmark.
  private func legInstrumentId(at index: Int) -> String {
    let leg = draft.legDrafts[index]
    if let acctId = leg.accountId, let account = accounts.by(id: acctId) {
      return account.instrument.id
    }
    if let emId = leg.earmarkId, let earmark = earmarks.by(id: emId) {
      return earmark.instrument.id
    }
    return ""
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

  /// Binding for counterpart amount text.
  private var counterpartAmountBinding: Binding<String> {
    Binding(
      get: { draft.counterpartLeg?.amountText ?? "" },
      set: { draft.setCounterpartAmount($0) }
    )
  }

  /// Derived exchange rate (display text + accessibility label), or nil when not computable.
  private var derivedRate: (displayText: String, accessibilityText: String)? {
    guard let relevantInst = relevantInstrument,
      let counterpartInst = counterpartInstrument,
      let primaryQty = InstrumentAmount.parseQuantity(
        from: draft.amountText, decimals: relevantInst.decimals),
      let counterQty = InstrumentAmount.parseQuantity(
        from: draft.counterpartLeg?.amountText ?? "", decimals: counterpartInst.decimals),
      primaryQty != .zero && counterQty != .zero
    else { return nil }
    // abs() used only for display rate computation — stored amounts preserve their signs
    let absPrimary = abs(primaryQty)
    let absCounter = abs(counterQty)
    let rate = absCounter / absPrimary
    let rateFormatted = rate.formatted(
      .number.precision(.significantDigits(2...4)).grouping(.never))
    return (
      displayText: "≈ 1 \(relevantInst.id) = \(rateFormatted) \(counterpartInst.id)",
      accessibilityText:
        "Approximate exchange rate: 1 \(relevantInst.id) equals \(rateFormatted) \(counterpartInst.id)"
    )
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
      .overlayPreferenceValue(LegCategoryPickerAnchorKey.self) { anchors in
        legCategoryOverlay(anchors: anchors)
      }
      .navigationTitle("Transaction Details")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .onAppear {
        if isNewTransaction {
          focusedField = isSimpleEarmarkOnly ? .amount : .payee
        }
      }
      .onChange(of: draft) { _, _ in debouncedSave() }
      .onChange(of: legCategoryFieldFocused) { _, focused in
        for i in draft.legDrafts.indices {
          if i != focused {
            showLegCategorySuggestions[i] = false
            legCategoryHighlightedIndex[i] = nil
            if let catId = draft.legDrafts[i].categoryId, let cat = categories.by(id: catId) {
              if draft.legDrafts[i].categoryText != categories.path(for: cat) {
                legCategoryJustSelected[i] = true
                draft.legDrafts[i].categoryText = categories.path(for: cat)
              }
            } else if !draft.legDrafts[i].categoryText.isEmpty {
              legCategoryJustSelected[i] = true
              draft.legDrafts[i].categoryText = ""
              draft.legDrafts[i].categoryId = nil
            }
          }
        }
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
            legPendingDeletion = nil
          }
        }
      } message: {
        Text("Are you sure you want to delete this sub-transaction?")
      }
  }

  private var formContent: some View {
    Form {
      if isSimpleEarmarkOnly {
        earmarkOnlyDetailsSection
        if showRecurrence {
          recurrenceSection
        }
        notesSection
      } else if draft.isCustom {
        typeSection.disabled(!isEditable)
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
        typeSection.disabled(!isEditable)
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
        LabeledContent("Type") {
          Text(TransactionType.openingBalance.displayName)
            .foregroundStyle(.secondary)
        }
      } else if !transaction.isSimple {
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
        TextField("Amount", text: amountBinding)
          .multilineTextAlignment(.trailing)
          .monospacedDigit()
          #if os(iOS)
            .keyboardType(.decimalPad)
          #endif
          .focused($focusedField, equals: .amount)
          .onSubmit {
            if isCrossCurrency {
              focusedField = .counterpartAmount
            }
          }
        Text(relevantInstrument?.id ?? "").foregroundStyle(.secondary)
          .monospacedDigit()
      }

      DatePicker("Date", selection: $draft.date, displayedComponents: .date)
    }
  }

  private var accountSection: some View {
    Section {
      Picker("Account", selection: $draft.legDrafts[draft.relevantLegIndex].accountId) {
        Text("None").tag(UUID?.none)
        ForEach(sortedAccounts) { account in
          Text(account.name).tag(UUID?.some(account.id))
        }
      }

      if draft.type == .transfer {
        let counterpartIndex = draft.relevantLegIndex == 0 ? 1 : 0
        let toAccountLabel = draft.showFromAccount ? "From Account" : "To Account"
        let currentAccountId = draft.legDrafts[draft.relevantLegIndex].accountId
        let eligibleAccounts = eligibleTransferAccounts(excluding: currentAccountId)

        Picker(toAccountLabel, selection: $draft.legDrafts[counterpartIndex].accountId) {
          Text("Select...").tag(UUID?.none)
          ForEach(eligibleAccounts) { account in
            Text(account.name).tag(UUID?.some(account.id))
          }
        }
        .onChange(of: draft.legDrafts[counterpartIndex].accountId) { _, _ in
          draft.snapToSameCurrencyIfNeeded(accounts: accounts)
        }

        if isCrossCurrency {
          let fieldLabel = draft.showFromAccount ? "Sent" : "Received"
          HStack {
            Text(fieldLabel)
            Spacer()
            TextField(fieldLabel, text: counterpartAmountBinding)
              .multilineTextAlignment(.trailing)
              .monospacedDigit()
              .accessibilityLabel(draft.showFromAccount ? "Sent amount" : "Received amount")
              #if os(iOS)
                .keyboardType(.decimalPad)
              #endif
              .focused($focusedField, equals: .counterpartAmount)
              .onSubmit { focusedField = nil }
            Text(counterpartInstrument?.id ?? "")
              .foregroundStyle(.secondary)
              .monospacedDigit()
          }

          if let rate = derivedRate {
            Text(rate.displayText)
              .font(.caption)
              .foregroundStyle(.secondary)
              .monospacedDigit()
              .accessibilityLabel(rate.accessibilityText)
          }
        }
      }
    }
  }

  @FocusState private var categoryFieldFocused: Bool
  @FocusState private var legCategoryFieldFocused: Int?

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
    let isLegEarmarkOnly = draft.legDrafts[index].isEarmarkOnly
    Section("Sub-transaction \(index + 1) of \(draft.legDrafts.count)") {
      if !isLegEarmarkOnly {
        Picker("Type", selection: $draft.legDrafts[index].type) {
          Text(TransactionType.income.displayName).tag(TransactionType.income)
          Text(TransactionType.expense.displayName).tag(TransactionType.expense)
          Text(TransactionType.transfer.displayName).tag(TransactionType.transfer)
        }
      }

      Picker("Account", selection: $draft.legDrafts[index].accountId) {
        Text("None").tag(UUID?.none)
        ForEach(sortedAccounts) { account in
          Text(account.name).tag(UUID?.some(account.id))
        }
      }
      .onChange(of: draft.legDrafts[index].accountId) { _, _ in
        draft.enforceEarmarkOnlyInvariants(at: index)
        draft.legDrafts[index].instrumentId = nil
      }

      Picker(
        "Currency",
        selection: Binding(
          get: { draft.legDrafts[index].instrumentId ?? legInstrumentId(at: index) },
          set: { draft.legDrafts[index].instrumentId = $0 }
        )
      ) {
        ForEach(availableInstruments) { instrument in
          Text("\(instrument.id) — \(CurrencyPicker.currencyName(for: instrument.id))")
            .tag(instrument.id)
        }
      }
      .accessibilityLabel("Currency for sub-transaction \(index + 1)")
      .accessibilityHint("Overrides the currency derived from the account")

      HStack {
        TextField("Amount", text: $draft.legDrafts[index].amountText)
          .multilineTextAlignment(.trailing)
          .monospacedDigit()
          #if os(iOS)
            .keyboardType(.decimalPad)
          #endif
          .focused($focusedField, equals: .legAmount(index))
        Text(draft.legDrafts[index].instrumentId ?? legInstrumentId(at: index))
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }

      if !isLegEarmarkOnly {
        LegCategoryAutocompleteField(
          legIndex: index,
          text: $draft.legDrafts[index].categoryText,
          highlightedIndex: Binding(
            get: { legCategoryHighlightedIndex[index] ?? nil },
            set: { legCategoryHighlightedIndex[index] = $0 }
          ),
          suggestionCount: legCategoryVisibleSuggestions(for: index).count,
          onTextChange: { _ in
            if legCategoryJustSelected[index] == true {
              legCategoryJustSelected[index] = false
            } else {
              showLegCategorySuggestions[index] = true
            }
          },
          onAcceptHighlighted: { acceptHighlightedLegCategory(at: index) }
        )
        .focused($legCategoryFieldFocused, equals: index)
      }

      Picker("Earmark", selection: $draft.legDrafts[index].earmarkId) {
        if !isLegEarmarkOnly {
          Text("None").tag(UUID?.none)
        }
        ForEach(earmarks.ordered.filter { !$0.isHidden }) { earmark in
          Text(earmark.name).tag(UUID?.some(earmark.id))
        }
      }
      #if os(macOS)
        .pickerStyle(.menu)
      #endif
      .onChange(of: draft.legDrafts[index].earmarkId) { _, _ in
        draft.enforceEarmarkOnlyInvariants(at: index)
      }

      if draft.legDrafts.count > 1 {
        Button(role: .destructive) {
          legPendingDeletion = index
        } label: {
          Text("Delete Sub-transaction")
            .frame(maxWidth: .infinity)
        }
        .accessibilityLabel("Delete Sub-transaction")
      }
    }
  }

  private var addSubTransactionSection: some View {
    Section {
      Button("Add Sub-transaction") {
        draft.addLeg(defaultAccountId: sortedAccounts.first?.id)
      }
      .accessibilityLabel("Add Sub-transaction")
    }
  }

  private var recurrenceSection: some View {
    Section("Recurrence") {
      Toggle("Repeat", isOn: $draft.isRepeating)
        .onChange(of: draft.isRepeating) { _, newValue in
          if newValue {
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
    Section("Notes") {
      TextEditor(text: $draft.notes)
        .accessibilityLabel("Notes")
        .frame(minHeight: 60, maxHeight: 120)
    }
  }

  private var isScheduled: Bool {
    showRecurrence && transaction.recurPeriod != nil
  }

  private var paySection: some View {
    Section {
      Button {
        Task {
          switch await transactionStore.payScheduledTransaction(transaction) {
          case .paid(let updated?): onUpdate(updated)
          case .paid(.none), .deleted: onDelete(transaction.id)
          case .failed: break
          }
        }
      } label: {
        HStack {
          Spacer()
          if transactionStore.isPayingScheduled {
            ProgressView()
              .controlSize(.small)
          } else {
            Text("Pay Now")
          }
          Spacer()
        }
      }
      .disabled(transactionStore.isPayingScheduled)
      .accessibilityLabel("Pay \(transaction.payee ?? "transaction") now")
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

  private var earmarkOnlyDetailsSection: some View {
    Section {
      LabeledContent("Type") {
        Text("Earmark funds")
          .foregroundStyle(.secondary)
      }

      Picker("Earmark", selection: $draft.earmarkId) {
        ForEach(earmarks.ordered.filter { !$0.isHidden }) { earmark in
          Text(earmark.name).tag(UUID?.some(earmark.id))
        }
      }
      #if os(macOS)
        .pickerStyle(.menu)
      #endif

      HStack {
        TextField("Amount", text: amountBinding)
          .multilineTextAlignment(.trailing)
          .monospacedDigit()
          #if os(iOS)
            .keyboardType(.decimalPad)
          #endif
        Text(earmarkInstrumentId ?? "").foregroundStyle(.secondary)
          .monospacedDigit()
      }

      DatePicker("Date", selection: $draft.date, displayedComponents: .date)
    }
  }

  /// The instrument ID for the earmark on the relevant leg.
  private var earmarkInstrumentId: String? {
    draft.relevantLeg.earmarkId
      .flatMap { earmarks.by(id: $0) }?
      .instrument.id
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
      draft.applyAutofill(from: match, categories: categories)
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

  // MARK: - Leg Category Suggestions

  private func legCategoryVisibleSuggestions(for index: Int) -> [CategorySuggestion] {
    guard showLegCategorySuggestions[index] == true else { return [] }
    let text = draft.legDrafts[index].categoryText
    let allEntries = categories.flattenedByPath()
    let filtered: [Categories.FlatEntry]
    if text.trimmingCharacters(in: .whitespaces).isEmpty {
      filtered = allEntries
    } else {
      filtered = allEntries.filter { matchesCategorySearch($0.path, query: text) }
    }
    return filtered.prefix(8).map { CategorySuggestion(id: $0.category.id, path: $0.path) }
  }

  private func acceptHighlightedLegCategory(at index: Int) {
    let suggestions = legCategoryVisibleSuggestions(for: index)
    guard let highlighted = legCategoryHighlightedIndex[index] ?? nil,
      highlighted < suggestions.count
    else { return }
    let selected = suggestions[highlighted]
    legCategoryJustSelected[index] = true
    draft.legDrafts[index].categoryId = selected.id
    draft.legDrafts[index].categoryText = selected.path
    showLegCategorySuggestions[index] = false
    legCategoryHighlightedIndex[index] = nil
  }

  @ViewBuilder
  private func legCategoryOverlay(anchors: [Int: Anchor<CGRect>]) -> some View {
    if let activeIndex = anchors.keys.sorted().first(where: { index in
      showLegCategorySuggestions[index] == true
        && !legCategoryVisibleSuggestions(for: index).isEmpty
    }), let anchor = anchors[activeIndex] {
      GeometryReader { proxy in
        let rect = proxy[anchor]
        CategorySuggestionDropdown(
          suggestions: legCategoryVisibleSuggestions(for: activeIndex),
          searchText: draft.legDrafts[activeIndex].categoryText,
          highlightedIndex: Binding(
            get: { legCategoryHighlightedIndex[activeIndex] ?? nil },
            set: { legCategoryHighlightedIndex[activeIndex] = $0 }
          ),
          onSelect: { selected in
            legCategoryJustSelected[activeIndex] = true
            draft.legDrafts[activeIndex].categoryId = selected.id
            draft.legDrafts[activeIndex].categoryText = selected.path
            showLegCategorySuggestions[activeIndex] = false
            legCategoryHighlightedIndex[activeIndex] = nil
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
    guard
      let updated = draft.toTransaction(
        id: transaction.id, accounts: accounts, earmarks: earmarks,
        availableInstruments: availableInstruments)
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
        Account(id: accountId, name: "Checking", type: .bank, instrument: .AUD),
        Account(name: "Savings", type: .bank, instrument: .AUD),
      ]),
      categories: Categories(from: [
        Category(name: "Groceries"),
        Category(name: "Transport"),
      ]),
      earmarks: Earmarks(from: [
        Earmark(name: "Holiday Fund", instrument: .AUD)
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
        Account(id: accountId1, name: "Checking", type: .bank, instrument: .AUD),
        Account(
          id: accountId2, name: "Credit Card", type: .creditCard, instrument: .AUD),
      ]),
      categories: Categories(from: [
        Category(name: "Groceries"),
        Category(name: "Transport"),
      ]),
      earmarks: Earmarks(from: [
        Earmark(name: "Holiday Fund", instrument: .AUD)
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

#Preview("Earmark-Only Transaction") {
  let earmarkId = UUID()
  NavigationStack {
    TransactionDetailView(
      transaction: Transaction(
        date: Date(),
        legs: [
          TransactionLeg(
            accountId: nil, instrument: .AUD, quantity: 500, type: .income,
            earmarkId: earmarkId)
        ]
      ),
      accounts: Accounts(from: [
        Account(name: "Checking", type: .bank, instrument: .AUD),
        Account(name: "Savings", type: .bank, instrument: .AUD),
      ]),
      categories: Categories(from: []),
      earmarks: Earmarks(from: [
        Earmark(id: earmarkId, name: "Income Tax FY2025", instrument: .AUD),
        Earmark(name: "Holiday Fund", instrument: .AUD),
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

#Preview("Cross-Currency Transfer") {
  let accountId1 = UUID()
  let accountId2 = UUID()
  NavigationStack {
    TransactionDetailView(
      transaction: Transaction(
        date: Date(),
        payee: "Currency Exchange",
        legs: [
          TransactionLeg(accountId: accountId1, instrument: .USD, quantity: -100, type: .transfer),
          TransactionLeg(accountId: accountId2, instrument: .AUD, quantity: 155, type: .transfer),
        ]
      ),
      accounts: Accounts(from: [
        Account(id: accountId1, name: "US Checking", type: .bank, instrument: .USD),
        Account(id: accountId2, name: "AU Savings", type: .bank, instrument: .AUD),
        Account(name: "Credit Card", type: .creditCard, instrument: .USD),
      ]),
      categories: Categories(from: []),
      earmarks: Earmarks(from: []),
      transactionStore: {
        let (backend, _) = PreviewBackend.create()
        return TransactionStore(
          repository: backend.transactions,
          conversionService: backend.conversionService,
          targetInstrument: .AUD
        )
      }(),
      viewingAccountId: accountId1,
      supportsComplexTransactions: true,
      onUpdate: { _ in },
      onDelete: { _ in }
    )
  }
}

#Preview("Cross-Currency Transfer (Sent)") {
  let accountId1 = UUID()
  let accountId2 = UUID()
  NavigationStack {
    TransactionDetailView(
      transaction: Transaction(
        date: Date(),
        payee: "Currency Exchange",
        legs: [
          TransactionLeg(accountId: accountId1, instrument: .USD, quantity: -100, type: .transfer),
          TransactionLeg(accountId: accountId2, instrument: .AUD, quantity: 155, type: .transfer),
        ]
      ),
      accounts: Accounts(from: [
        Account(id: accountId1, name: "US Checking", type: .bank, instrument: .USD),
        Account(id: accountId2, name: "AU Savings", type: .bank, instrument: .AUD),
      ]),
      categories: Categories(from: []),
      earmarks: Earmarks(from: []),
      transactionStore: {
        let (backend, _) = PreviewBackend.create()
        return TransactionStore(
          repository: backend.transactions,
          conversionService: backend.conversionService,
          targetInstrument: .AUD
        )
      }(),
      viewingAccountId: accountId2,
      supportsComplexTransactions: true,
      onUpdate: { _ in },
      onDelete: { _ in }
    )
  }
}
