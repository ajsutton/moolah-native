import SwiftUI

struct TransactionDetailView: View {
  let transaction: Transaction
  let accounts: Accounts
  let categories: Categories
  let earmarks: Earmarks
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
  @State private var saveTask: Task<Void, Never>?
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
    onUpdate: @escaping (Transaction) -> Void,
    onDelete: @escaping (UUID) -> Void
  ) {
    self.transaction = transaction
    self.accounts = accounts
    self.categories = categories
    self.earmarks = earmarks
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
    guard let amount = Double(cleaned), amount >= 0 else { return nil }
    return Int(amount * 100)
  }

  private func categoryLabel(for category: Category) -> String {
    if let parentId = category.parentId,
      let parent = categories.by(id: parentId)
    {
      return "\(parent.name):\(category.name)"
    }
    return category.name
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
      recurrenceSection
      notesSection
      deleteSection
    }
    .formStyle(.grouped)
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
      TextField("Payee", text: $payee)
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
      Picker("Category", selection: $categoryId) {
        Text("None").tag(UUID?.none)
        ForEach(categories.roots) { root in
          Text(root.name).tag(UUID?.some(root.id))
          ForEach(categories.children(of: root.id)) { child in
            Text(categoryLabel(for: child)).tag(UUID?.some(child.id))
          }
        }
      }
      #if os(macOS)
        .pickerStyle(.menu)
      #endif

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
          .frame(height: 60)
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

  private func debouncedSave() {
    // Cancel any pending save
    saveTask?.cancel()

    // Schedule a new save after a short delay
    saveTask = Task {
      try? await Task.sleep(nanoseconds: 300_000_000)  // 300ms debounce
      guard !Task.isCancelled else { return }
      await MainActor.run {
        saveIfValid()
      }
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
      amount: MonetaryAmount(cents: signedCents, currency: Currency.defaultCurrency),
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
        amount: MonetaryAmount(cents: -5023, currency: Currency.defaultCurrency),
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
      onUpdate: { _ in },
      onDelete: { _ in }
    )
  }
}
