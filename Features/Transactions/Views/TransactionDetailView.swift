import SwiftUI

// MARK: - TEMPORARY STUB
// This view is temporarily stubbed during the TransactionDraft rewrite (Tasks 3-7).
// Task 8 will rewrite this view to use the new unified draft model.

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
    if let catId = initialDraft.legDrafts.first(where: { $0.categoryId != nil })?.categoryId,
      let cat = categories.by(id: catId)
    {
      initialDraft.categoryText = categories.path(for: cat)
    }
    _draft = State(initialValue: initialDraft)
  }

  var body: some View {
    // Temporary stub — will be rewritten in Task 8
    Text("Transaction Detail (stub)")
      .navigationTitle("Transaction Details")
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
