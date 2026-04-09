import SwiftUI

struct TransactionDetailView: View {
  let transaction: Transaction
  let accounts: Accounts
  let categories: Categories
  let earmarks: Earmarks
  let transactionStore: TransactionStore
  let showRecurrence: Bool
  let onUpdate: (Transaction) -> Void
  let onDelete: (UUID) -> Void

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
  @State private var showPayeeSuggestions = false
  @State private var payeeHighlightedIndex: Int?
  @FocusState private var focusedField: Field?

  private enum Field: Hashable {
    case payee
    case amount
  }

  init(
    transaction: Transaction,
    accounts: Accounts,
    categories: Categories,
    earmarks: Earmarks,
    transactionStore: TransactionStore,
    showRecurrence: Bool = false,
    onUpdate: @escaping (Transaction) -> Void,
    onDelete: @escaping (UUID) -> Void
  ) {
    self.transaction = transaction
    self.accounts = accounts
    self.categories = categories
    self.earmarks = earmarks
    self.transactionStore = transactionStore
    self.showRecurrence = showRecurrence
    self.onUpdate = onUpdate
    self.onDelete = onDelete

    _type = State(initialValue: transaction.type)
    _payee = State(initialValue: transaction.payee ?? "")
    _amountText = State(initialValue: transaction.amount.formatNoSymbol)
    _date = State(initialValue: transaction.date)
    _accountId = State(initialValue: transaction.accountId)
    _toAccountId = State(initialValue: transaction.toAccountId)
    _categoryId = State(initialValue: transaction.categoryId)
    _earmarkId = State(initialValue: transaction.earmarkId)
    _notes = State(initialValue: transaction.notes ?? "")
    _recurPeriod = State(initialValue: transaction.recurPeriod)
    _recurEvery = State(initialValue: transaction.recurEvery ?? 1)
    _isRepeating = State(
      initialValue: transaction.recurPeriod != nil && transaction.recurPeriod != .once)
  }

  private var isNewTransaction: Bool {
    // Detect if this is a new transaction by checking if it has default values
    transaction.amount.cents == 0 && (transaction.payee?.isEmpty ?? true)
  }

  private var parsedCents: Int? {
    let cleaned = amountText.filter { $0.isNumber || $0 == "." }
    guard let decimal = Decimal(string: cleaned), decimal >= 0 else { return nil }
    return NSDecimalNumber(decimal: decimal * 100).intValue
  }

  private var isValid: Bool {
    guard parsedCents != nil else { return false }
    if type == .transfer {
      guard toAccountId != nil, toAccountId != accountId else { return false }
    }
    if isRepeating {
      guard recurPeriod != nil, recurEvery >= 1 else { return false }
    }
    return true
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
    Form {
      typeSection
      detailsSection
      accountSection
      categorySection
      if showRecurrence {
        recurrenceSection
      }
      notesSection
      if isScheduled {
        paySection
      }
      deleteSection
    }
    .formStyle(.grouped)
    .overlayPreferenceValue(PayeeFieldAnchorKey.self) { anchor in
      if showPayeeSuggestions, !payee.isEmpty,
        !transactionStore.payeeSuggestions.isEmpty, let anchor
      {
        GeometryReader { proxy in
          let rect = proxy[anchor]
          PayeeSuggestionDropdown(
            suggestions: transactionStore.payeeSuggestions,
            searchText: payee,
            highlightedIndex: $payeeHighlightedIndex,
            onSelect: { selected in
              showPayeeSuggestions = false
              payeeHighlightedIndex = nil
              payee = selected
              transactionStore.clearPayeeSuggestions()
              autofillFromPayee(selected)
            }
          )
          .frame(width: rect.width)
          .offset(x: rect.minX, y: rect.maxY + 4)
        }
      }
    }
    .navigationTitle("Transaction Details")
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
    .onAppear {
      // Focus payee field for new transactions
      if isNewTransaction {
        focusedField = .payee
      }
    }
    .onChange(of: type) { _, _ in debouncedSave() }
    .onChange(of: payee) { _, _ in debouncedSave() }
    .onChange(of: amountText) { _, _ in debouncedSave() }
    .onChange(of: date) { _, _ in debouncedSave() }
    .onChange(of: accountId) { _, _ in debouncedSave() }
    .onChange(of: toAccountId) { _, _ in debouncedSave() }
    .onChange(of: categoryId) { _, _ in debouncedSave() }
    .onChange(of: earmarkId) { _, _ in debouncedSave() }
    .onChange(of: notes) { _, _ in debouncedSave() }
    .onChange(of: isRepeating) { _, _ in debouncedSave() }
    .onChange(of: recurPeriod) { _, _ in debouncedSave() }
    .onChange(of: recurEvery) { _, _ in debouncedSave() }
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
        Picker("Type", selection: $type) {
          ForEach(TransactionType.userSelectableTypes, id: \.self) { t in
            Text(t.displayName).tag(t)
          }
        }
        .onChange(of: type) { oldValue, newValue in
          if newValue == .transfer && toAccountId == nil {
            // Set first available account (excluding current account) as default
            toAccountId = sortedAccounts.first { $0.id != accountId }?.id
          }
        }
      }
    }
  }

  private var detailsSection: some View {
    Section {
      PayeeAutocompleteField(
        text: $payee,
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
        TextField("Amount", text: $amountText)
          .multilineTextAlignment(.trailing)
          #if os(iOS)
            .keyboardType(.decimalPad)
          #endif
        Text(transaction.amount.currency.code).foregroundStyle(.secondary)
      }

      DatePicker("Date", selection: $date, displayedComponents: .date)
    }
  }

  private var accountSection: some View {
    Section {
      Picker("Account", selection: $accountId) {
        Text("None").tag(UUID?.none)
        ForEach(sortedAccounts) { account in
          Text(account.name).tag(UUID?.some(account.id))
        }
      }

      if type == .transfer {
        Picker("To Account", selection: $toAccountId) {
          Text("Select...").tag(UUID?.none)
          ForEach(sortedAccounts.filter { $0.id != accountId && !$0.isHidden }) { account in
            Text(account.name).tag(UUID?.some(account.id))
          }
        }
      }
    }
  }

  private var categorySection: some View {
    Section {
      CategoryPicker(categories: categories, selection: $categoryId)

      Picker("Earmark", selection: $earmarkId) {
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
        TextEditor(text: $notes)
          .frame(minHeight: 60, maxHeight: 120)
          .scrollContentBackground(.hidden)
          .padding()
          #if os(macOS)
            .background(Color(nsColor: .textBackgroundColor))
          #else
            .background(Color(uiColor: .systemBackground))
          #endif
          .overlay(
            RoundedRectangle(cornerRadius: 4)
              #if os(macOS)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
              #else
                .stroke(Color(uiColor: .separator), lineWidth: 1)
              #endif
          )
      }
    }
  }

  @State private var isPaying = false

  private var isScheduled: Bool {
    showRecurrence && (transaction.recurPeriod != nil || transaction.recurPeriod == .once)
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
    guard showPayeeSuggestions, !payee.isEmpty else { return [] }
    return transactionStore.payeeSuggestions
      .filter { $0.localizedCaseInsensitiveCompare(payee) != .orderedSame }
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
    payee = selected
    transactionStore.clearPayeeSuggestions()
    autofillFromPayee(selected)
  }

  private func autofillFromPayee(_ selectedPayee: String) {
    Task {
      guard let match = await transactionStore.fetchTransactionForAutofill(payee: selectedPayee)
      else { return }
      // Auto-fill fields that are still at defaults
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

  private func debouncedSave() {
    transactionStore.debouncedSave { [self] in
      saveIfValid()
    }
  }

  private func saveIfValid() {
    guard isValid, let cents = parsedCents else { return }

    let signedCents: Int
    switch type {
    case .expense: signedCents = -abs(cents)
    case .income: signedCents = abs(cents)
    case .transfer: signedCents = -abs(cents)
    case .openingBalance: signedCents = abs(cents)  // Should never be edited
    }

    let updated = Transaction(
      id: transaction.id,
      type: type,
      date: date,
      accountId: accountId,
      toAccountId: type == .transfer ? toAccountId : nil,
      amount: MonetaryAmount(cents: signedCents, currency: transaction.amount.currency),
      payee: payee.isEmpty ? nil : payee,
      notes: notes.isEmpty ? nil : notes,
      categoryId: categoryId,
      earmarkId: earmarkId,
      recurPeriod: isRepeating ? recurPeriod : nil,
      recurEvery: isRepeating ? recurEvery : nil
    )

    onUpdate(updated)
  }
}

#Preview {
  let accountId = UUID()
  NavigationStack {
    TransactionDetailView(
      transaction: Transaction(
        type: .expense,
        date: Date(),
        accountId: accountId,
        amount: MonetaryAmount(cents: -5023, currency: Currency.AUD),
        payee: "Woolworths"
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
      transactionStore: TransactionStore(repository: InMemoryTransactionRepository()),
      onUpdate: { _ in },
      onDelete: { _ in }
    )
  }
}
