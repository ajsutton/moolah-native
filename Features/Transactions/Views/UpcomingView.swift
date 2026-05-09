// swiftlint:disable multiline_arguments

import SwiftData
import SwiftUI

struct UpcomingView: View {
  let accounts: Accounts
  let categories: Categories
  let earmarks: Earmarks
  let transactionStore: TransactionStore

  @State private var selectedTransaction: Transaction?
  @State private var pendingPayId: Transaction.ID?
  @State private var transactionPendingDelete: Transaction.ID?

  var body: some View {
    TransactionListView(
      title: "Upcoming",
      filter: TransactionFilter(scheduled: .scheduledOnly),
      accounts: accounts,
      categories: categories,
      earmarks: earmarks,
      transactionStore: transactionStore,
      grouping: .scheduledStatus(today: Date(), pendingPayId: $pendingPayId),
      selectedTransaction: $selectedTransaction
    )
    .transactionInspector(
      selectedTransaction: $selectedTransaction,
      accounts: accounts,
      categories: categories,
      earmarks: earmarks,
      transactionStore: transactionStore,
      showRecurrence: true
    )
    .focusedSceneValue(\.selectedTransaction, $selectedTransaction)
    .onChange(of: pendingPayId) { _, newId in
      guard let id = newId,
        let match = transactionStore.transactions.first(where: { $0.transaction.id == id })
      else { return }
      Task {
        await payTransaction(match.transaction)
        await MainActor.run { pendingPayId = nil }
      }
    }
    .confirmationDialog(
      "Delete this transaction?",
      isPresented: Binding(
        get: { transactionPendingDelete != nil },
        set: { if !$0 { transactionPendingDelete = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Delete Transaction", role: .destructive) {
        if let id = transactionPendingDelete {
          Task { await transactionStore.delete(id: id) }
        }
        transactionPendingDelete = nil
      }
      Button("Cancel", role: .cancel) { transactionPendingDelete = nil }
    } message: {
      Text("This action cannot be undone.")
    }
    .onReceive(NotificationCenter.default.publisher(for: .requestTransactionEdit)) { note in
      guard let id = note.object as? Transaction.ID,
        let match = transactionStore.transactions.first(where: { $0.transaction.id == id })
      else { return }
      selectedTransaction = match.transaction
    }
    .onReceive(NotificationCenter.default.publisher(for: .requestTransactionDelete)) { note in
      guard let id = note.object as? Transaction.ID,
        transactionStore.transactions.contains(where: { $0.transaction.id == id })
      else { return }
      transactionPendingDelete = id
    }
    // Per design §10, .requestTransactionPay handler also stays —
    // window-menu commands need a path to trigger Pay on the visible
    // leaf. Routes through the same pendingPayId binding so the
    // in-progress visual fires regardless of trigger source.
    .onReceive(NotificationCenter.default.publisher(for: .requestTransactionPay)) { note in
      guard let id = note.object as? Transaction.ID,
        transactionStore.transactions.contains(where: { $0.transaction.id == id })
      else { return }
      pendingPayId = id
    }
  }

  private func payTransaction(_ scheduledTransaction: Transaction) async {
    let result = await transactionStore.payScheduledTransaction(scheduledTransaction)
    switch result {
    case .paid(let updated):
      selectedTransaction = updated
    case .deleted:
      selectedTransaction = nil
    case .failed:
      break
    }
  }
}

@MainActor
private func previewSeedTransactions(
  backend: any BackendProvider,
  accountId: UUID,
  categoryId: UUID,
  store: TransactionStore
) async {
  let today = Date()
  let calendar = Calendar.current
  let overdue = calendar.date(byAdding: .day, value: -5, to: today) ?? today
  let upcoming = calendar.date(byAdding: .day, value: 5, to: today) ?? today

  _ = try? await backend.transactions.create(
    Transaction(
      date: overdue, payee: "Rent",
      recurPeriod: .month, recurEvery: 1,
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: .AUD, quantity: -2000, type: .expense,
          categoryId: categoryId)
      ]))
  _ = try? await backend.transactions.create(
    Transaction(
      date: upcoming, payee: "Internet",
      recurPeriod: .month, recurEvery: 1,
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: .AUD, quantity: -150, type: .expense,
          categoryId: categoryId)
      ]))
  await store.load(filter: TransactionFilter(scheduled: .scheduledOnly))
}

#Preview {
  let accountId = UUID()
  let categoryId = UUID()
  let accounts = Accounts(from: [
    Account(
      id: accountId, name: "Checking", type: .bank, instrument: .AUD,
      positions: [Position(instrument: .AUD, quantity: 2449.77)])
  ])
  let categories = Categories(from: [
    Category(id: categoryId, name: "Rent", parentId: nil)
  ])
  let (backend, _) = PreviewBackend.create()
  let store = TransactionStore(
    repository: backend.transactions,
    conversionService: backend.conversionService,
    targetInstrument: .AUD)
  return NavigationStack {
    UpcomingView(
      accounts: accounts, categories: categories,
      earmarks: Earmarks(from: []), transactionStore: store)
  }
  .task {
    await previewSeedTransactions(
      backend: backend, accountId: accountId, categoryId: categoryId, store: store)
  }
}
