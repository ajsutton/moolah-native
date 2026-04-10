import SwiftUI

struct TransactionFormView: View {
  let accounts: Accounts
  let categories: Categories
  let earmarks: Earmarks
  let existing: Transaction?
  let transactionStore: TransactionStore?
  let onSave: (Transaction) -> Void
  let onDelete: ((UUID) -> Void)?

  @Environment(\.dismiss) private var dismiss

  @State private var type: TransactionType
  @State private var payee: String
  @State private var amountText: String
  @State private var date: Date
  @State private var accountId: UUID?
  @State private var toAccountId: UUID?
  @State private var categoryId: UUID?
  @State private var earmarkId: UUID?
  @State private var notes: String
  @State private var recurPeriod: RecurPeriod?
  @State private var recurEvery: Int
  @State private var isRepeating: Bool
  @State private var showDeleteConfirmation = false
  @FocusState private var payeeFieldFocused: Bool
  @State private var showPayeeSuggestions = false
  @State private var payeeHighlightedIndex: Int?
  @State private var categoryText: String = ""
  @State private var showCategorySuggestions = false
  @State private var categoryHighlightedIndex: Int?
  @State private var categoryJustSelected = false

  init(
    accounts: Accounts,
    categories: Categories,
    earmarks: Earmarks,
    existing: Transaction? = nil,
    transactionStore: TransactionStore? = nil,
    onSave: @escaping (Transaction) -> Void,
    onDelete: ((UUID) -> Void)? = nil
  ) {
    self.accounts = accounts
    self.categories = categories
    self.earmarks = earmarks
    self.existing = existing
    self.transactionStore = transactionStore
    self.onSave = onSave
    self.onDelete = onDelete

    if let tx = existing {
      _type = State(initialValue: tx.type)
      _payee = State(initialValue: tx.payee ?? "")
      let decimal = Decimal(abs(tx.amount.cents)) / 100
      _amountText = State(initialValue: "\(decimal)")
      _date = State(initialValue: tx.date)
      _accountId = State(initialValue: tx.accountId)
      _toAccountId = State(initialValue: tx.toAccountId)
      _categoryId = State(initialValue: tx.categoryId)
      if let catId = tx.categoryId, let cat = categories.by(id: catId) {
        _categoryText = State(initialValue: categories.path(for: cat))
      }
      _earmarkId = State(initialValue: tx.earmarkId)
      _notes = State(initialValue: tx.notes ?? "")
      _recurPeriod = State(initialValue: tx.recurPeriod)
      _recurEvery = State(initialValue: tx.recurEvery ?? 1)
      _isRepeating = State(initialValue: tx.recurPeriod != nil && tx.recurPeriod != .once)
    } else {
      _type = State(initialValue: .expense)
      _payee = State(initialValue: "")
      _amountText = State(initialValue: "")
      _date = State(initialValue: Date())
      _accountId = State(initialValue: accounts.ordered.first?.id)
      _toAccountId = State(initialValue: nil)
      _categoryId = State(initialValue: nil)
      _earmarkId = State(initialValue: nil)
      _notes = State(initialValue: "")
      _recurPeriod = State(initialValue: nil)
      _recurEvery = State(initialValue: 1)
      _isRepeating = State(initialValue: false)
    }
  }

  private var selectedCurrency: Currency {
    accounts.ordered.first(where: { $0.id == accountId })?.balance.currency ?? .AUD
  }

  private var isEditing: Bool { existing != nil }

  private var title: String {
    isEditing ? "Edit Transaction" : "New Transaction"
  }

  private var parsedCents: Int? {
    guard let value = Decimal(string: amountText), value > 0 else { return nil }
    return NSDecimalNumber(decimal: value * 100).intValue
  }

  private var canSave: Bool {
    guard parsedCents != nil else { return false }
    if type == .transfer {
      guard toAccountId != nil, toAccountId != accountId else { return false }
    }
    if isRepeating {
      guard recurPeriod != nil, recurEvery >= 1 else { return false }
    }
    return true
  }

  var body: some View {
    NavigationStack {
      Form {
        typeSection
        detailsSection
        accountSection
        categorySection
        recurrenceSection
        notesSection

        if isEditing {
          deleteSection
        }
      }
      .formStyle(.grouped)
      .overlayPreferenceValue(PayeeFieldAnchorKey.self) { anchor in
        if let store = transactionStore, showPayeeSuggestions, !payee.isEmpty,
          !store.payeeSuggestions.isEmpty, let anchor
        {
          GeometryReader { proxy in
            let rect = proxy[anchor]
            PayeeSuggestionDropdown(
              suggestions: store.payeeSuggestions,
              searchText: payee,
              highlightedIndex: $payeeHighlightedIndex,
              onSelect: { selected in
                showPayeeSuggestions = false
                payeeHighlightedIndex = nil
                payee = selected
                store.clearPayeeSuggestions()
                autofillFromPayee(selected, store: store)
              }
            )
            .frame(width: rect.width)
            .offset(x: rect.minX, y: rect.maxY + 4)
          }
        }
      }
      .overlayPreferenceValue(CategoryPickerAnchorKey.self) { anchor in
        if showCategorySuggestions, !categoryVisibleSuggestions.isEmpty, let anchor {
          GeometryReader { proxy in
            let rect = proxy[anchor]
            CategorySuggestionDropdown(
              suggestions: categoryVisibleSuggestions,
              searchText: categoryText,
              highlightedIndex: $categoryHighlightedIndex,
              onSelect: { selected in
                categoryJustSelected = true
                categoryId = selected.id
                categoryText = selected.path
                showCategorySuggestions = false
                categoryHighlightedIndex = nil
              }
            )
            .frame(width: rect.width)
            .offset(x: rect.minX, y: rect.maxY + 4)
          }
        }
      }
      .navigationTitle(title)
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
            .keyboardShortcut(.cancelAction)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") { save() }
            .disabled(!canSave)
            .keyboardShortcut(.defaultAction)
        }
      }
      .confirmationDialog(
        "Delete Transaction",
        isPresented: $showDeleteConfirmation,
        titleVisibility: .visible
      ) {
        Button("Delete", role: .destructive) {
          if let id = existing?.id {
            onDelete?(id)
            dismiss()
          }
        }
      } message: {
        Text("Are you sure you want to delete this transaction? This cannot be undone.")
      }
    }
  }

  // MARK: - Sections

  private var typeSection: some View {
    Section {
      Picker("Type", selection: $type) {
        ForEach(TransactionType.userSelectableTypes, id: \.self) { t in
          Text(t.displayName).tag(t)
        }
      }
      .pickerStyle(.segmented)
    }
  }

  private var detailsSection: some View {
    Section {
      if transactionStore != nil {
        PayeeAutocompleteField(
          text: $payee,
          highlightedIndex: $payeeHighlightedIndex,
          suggestionCount: payeeVisibleSuggestionCount,
          onTextChange: { newValue in
            showPayeeSuggestions = !newValue.isEmpty
            transactionStore?.fetchPayeeSuggestions(prefix: newValue)
          },
          onAcceptHighlighted: acceptHighlightedPayee
        )
        .focused($payeeFieldFocused)
        .onChange(of: payeeFieldFocused) { _, focused in
          if !focused {
            showPayeeSuggestions = false
            payeeHighlightedIndex = nil
          }
        }
      } else {
        TextField("Payee", text: $payee)
      }

      HStack {
        Text(selectedCurrency.code)
          .foregroundStyle(.secondary)
        TextField("Amount", text: $amountText)
          #if os(iOS)
            .keyboardType(.decimalPad)
          #endif
      }

      DatePicker("Date", selection: $date, displayedComponents: .date)
    }
  }

  private var accountSection: some View {
    Section {
      Picker("Account", selection: $accountId) {
        Text("None").tag(UUID?.none)
        ForEach(accounts.ordered) { account in
          Text(account.name).tag(UUID?.some(account.id))
        }
      }

      if type == .transfer {
        Picker("To Account", selection: $toAccountId) {
          Text("Select...").tag(UUID?.none)
          ForEach(accounts.ordered.filter { $0.id != accountId }) { account in
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
        text: $categoryText,
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
          if let id = categoryId, let cat = categories.by(id: id) {
            categoryText = categories.path(for: cat)
          } else {
            categoryText = ""
            categoryId = nil
          }
        }
      }

      Picker("Earmark", selection: $earmarkId) {
        Text("None").tag(UUID?.none)
        ForEach(earmarks.ordered) { earmark in
          Text(earmark.name).tag(UUID?.some(earmark.id))
        }
      }
    }
  }

  private var recurrenceSection: some View {
    Section("Recurrence") {
      Toggle("Repeat", isOn: $isRepeating)
        .onChange(of: isRepeating) { _, newValue in
          if newValue {
            // Default to monthly recurrence when enabled
            if recurPeriod == nil || recurPeriod == .once {
              recurPeriod = .month
            }
          } else {
            recurPeriod = nil
          }
        }

      if isRepeating {
        HStack {
          Text("Every")
          Spacer()
          TextField("", value: $recurEvery, format: .number)
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
            get: { recurPeriod ?? .month },
            set: { recurPeriod = $0 }
          )
        ) {
          ForEach(RecurPeriod.allCases.filter { $0 != .once }, id: \.self) { period in
            Text(recurEvery == 1 ? period.displayName : period.pluralDisplayName)
              .tag(period)
          }
        }
        .accessibilityLabel("Recurrence period")
      }
    }
  }

  private var notesSection: some View {
    Section("Notes") {
      TextField("Notes", text: $notes, axis: .vertical)
        .lineLimit(3...6)
    }
  }

  private var deleteSection: some View {
    Section {
      Button("Delete Transaction", role: .destructive) {
        showDeleteConfirmation = true
      }
    }
  }

  // MARK: - Actions

  private var payeeVisibleSuggestions: [String] {
    guard showPayeeSuggestions, !payee.isEmpty, let store = transactionStore else { return [] }
    return store.payeeSuggestions
      .filter { $0.localizedCaseInsensitiveCompare(payee) != .orderedSame }
      .prefix(8).map { $0 }
  }

  private var payeeVisibleSuggestionCount: Int {
    payeeVisibleSuggestions.count
  }

  private func acceptHighlightedPayee() {
    guard let store = transactionStore,
      let index = payeeHighlightedIndex, index < payeeVisibleSuggestions.count
    else { return }
    let selected = payeeVisibleSuggestions[index]
    showPayeeSuggestions = false
    payeeHighlightedIndex = nil
    payee = selected
    store.clearPayeeSuggestions()
    autofillFromPayee(selected, store: store)
  }

  private func autofillFromPayee(_ selectedPayee: String, store: TransactionStore) {
    Task {
      guard let match = await store.fetchTransactionForAutofill(payee: selectedPayee) else {
        return
      }
      if parsedCents == nil || parsedCents == 0 {
        let decimal = Decimal(abs(match.amount.cents)) / 100
        amountText = "\(decimal)"
      }
      if categoryId == nil {
        categoryId = match.categoryId
      }
      if type == .expense && match.type != .expense {
        type = match.type
      }
      if type == .transfer, toAccountId == nil {
        toAccountId = match.toAccountId
      }
    }
  }

  // MARK: - Category Suggestions

  private var categoryVisibleSuggestions: [CategorySuggestion] {
    guard showCategorySuggestions else { return [] }
    let allEntries = categories.flattenedByPath()
    let filtered: [Categories.FlatEntry]
    if categoryText.trimmingCharacters(in: .whitespaces).isEmpty {
      filtered = allEntries
    } else {
      filtered = allEntries.filter { matchesCategorySearch($0.path, query: categoryText) }
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
    categoryId = selected.id
    categoryText = selected.path
    showCategorySuggestions = false
    categoryHighlightedIndex = nil
  }

  private func save() {
    guard let cents = parsedCents else { return }

    let signedCents: Int
    switch type {
    case .expense: signedCents = -abs(cents)
    case .income: signedCents = abs(cents)
    case .transfer: signedCents = -abs(cents)
    case .openingBalance: signedCents = abs(cents)  // Should never be created via form
    }

    let transaction = Transaction(
      id: existing?.id ?? UUID(),
      type: type,
      date: date,
      accountId: accountId,
      toAccountId: type == .transfer ? toAccountId : nil,
      amount: MonetaryAmount(cents: signedCents, currency: selectedCurrency),
      payee: payee.isEmpty ? nil : payee,
      notes: notes.isEmpty ? nil : notes,
      categoryId: categoryId,
      earmarkId: earmarkId,
      recurPeriod: isRepeating ? recurPeriod : nil,
      recurEvery: isRepeating ? recurEvery : nil
    )

    onSave(transaction)
    dismiss()
  }
}

#Preview("New") {
  let accountId = UUID()
  TransactionFormView(
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
    onSave: { _ in }
  )
}

#Preview("Edit") {
  let accountId = UUID()
  TransactionFormView(
    accounts: Accounts(from: [
      Account(id: accountId, name: "Checking", type: .bank),
      Account(name: "Savings", type: .bank),
    ]),
    categories: Categories(from: [
      Category(name: "Groceries"),
      Category(name: "Transport"),
    ]),
    earmarks: Earmarks(from: []),
    existing: Transaction(
      type: .expense,
      date: Date(),
      accountId: accountId,
      amount: MonetaryAmount(cents: -5023, currency: .AUD),
      payee: "Woolworths"
    ),
    onSave: { _ in },
    onDelete: { _ in }
  )
}
