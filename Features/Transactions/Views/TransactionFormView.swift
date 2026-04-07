import SwiftUI

struct TransactionFormView: View {
  let accounts: Accounts
  let categories: Categories
  let earmarks: Earmarks
  let existing: Transaction?
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
  @State private var showDeleteConfirmation = false

  init(
    accounts: Accounts,
    categories: Categories,
    earmarks: Earmarks,
    existing: Transaction? = nil,
    onSave: @escaping (Transaction) -> Void,
    onDelete: ((UUID) -> Void)? = nil
  ) {
    self.accounts = accounts
    self.categories = categories
    self.earmarks = earmarks
    self.existing = existing
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
      _earmarkId = State(initialValue: tx.earmarkId)
      _notes = State(initialValue: tx.notes ?? "")
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
    }
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
    return true
  }

  var body: some View {
    NavigationStack {
      Form {
        typeSection
        detailsSection
        accountSection
        categorySection
        notesSection

        if isEditing {
          deleteSection
        }
      }
      .navigationTitle(title)
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") { save() }
            .disabled(!canSave)
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
        ForEach(TransactionType.allCases, id: \.self) { t in
          Text(t.rawValue.capitalized).tag(t)
        }
      }
      .pickerStyle(.segmented)
    }
  }

  private var detailsSection: some View {
    Section {
      TextField("Payee", text: $payee)

      HStack {
        Text(Currency.defaultCurrency.code)
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

  private var categorySection: some View {
    Section {
      Picker("Category", selection: $categoryId) {
        Text("None").tag(UUID?.none)
        ForEach(categories.roots) { root in
          Text(root.name).tag(UUID?.some(root.id))
          ForEach(categories.children(of: root.id)) { child in
            Text("  \(child.name)").tag(UUID?.some(child.id))
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

  private func save() {
    guard let cents = parsedCents else { return }

    let signedCents: Int
    switch type {
    case .expense: signedCents = -abs(cents)
    case .income: signedCents = abs(cents)
    case .transfer: signedCents = -abs(cents)
    }

    let transaction = Transaction(
      id: existing?.id ?? UUID(),
      type: type,
      date: date,
      accountId: accountId,
      toAccountId: type == .transfer ? toAccountId : nil,
      amount: MonetaryAmount(cents: signedCents, currency: Currency.defaultCurrency),
      payee: payee.isEmpty ? nil : payee,
      notes: notes.isEmpty ? nil : notes,
      categoryId: categoryId,
      earmarkId: earmarkId,
      recurPeriod: existing?.recurPeriod,
      recurEvery: existing?.recurEvery
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
      amount: MonetaryAmount(cents: -5023, currency: Currency.defaultCurrency),
      payee: "Woolworths"
    ),
    onSave: { _ in },
    onDelete: { _ in }
  )
}
