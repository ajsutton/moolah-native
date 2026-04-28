// swiftlint:disable multiline_arguments

import SwiftData
import SwiftUI

struct UpcomingView: View {
  let accounts: Accounts
  let categories: Categories
  let earmarks: Earmarks
  let transactionStore: TransactionStore

  @Environment(ProfileSession.self) private var session
  @State private var selectedTransaction: Transaction?
  @State private var transactionPendingDelete: Transaction.ID?

  var body: some View {
    listView
      .transactionInspector(
        selectedTransaction: $selectedTransaction,
        accounts: accounts,
        categories: categories,
        earmarks: earmarks,
        transactionStore: transactionStore,
        showRecurrence: true
      )
      .focusedSceneValue(\.selectedTransaction, $selectedTransaction)
      .focusedSceneValue(\.newTransactionAction, createNewScheduledTransaction)
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
      .onReceive(NotificationCenter.default.publisher(for: .requestTransactionPay)) { note in
        guard let id = note.object as? Transaction.ID,
          let match = transactionStore.transactions.first(where: { $0.transaction.id == id })
        else { return }
        Task { await payTransaction(match.transaction) }
      }
  }

  private var listView: some View {
    List(selection: $selectedTransaction) {
      overdueSection
      upcomingSection
    }
    .profileNavigationTitle("Upcoming")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          createNewScheduledTransaction()
        } label: {
          Label("Add Scheduled Transaction", systemImage: "plus")
        }
      }
    }
    .task {
      await transactionStore.load(filter: TransactionFilter(scheduled: .scheduledOnly))
    }
    .refreshable {
      await transactionStore.load(filter: TransactionFilter(scheduled: .scheduledOnly))
    }
    .overlay {
      if !transactionStore.isLoading && transactionStore.transactions.isEmpty {
        ContentUnavailableView(
          "No Scheduled Transactions",
          systemImage: "calendar",
          description: Text(
            PlatformActionVerb.emptyStatePrompt(
              buttonLabel: "+",
              suffix: "to add a recurring transaction."
            )
          )
        )
      }
    }
  }

  @ViewBuilder private var overdueSection: some View {
    if !overdueTransactions.isEmpty {
      Section("Overdue") {
        ForEach(overdueTransactions) { entry in
          row(for: entry, isOverdue: true)
        }
      }
    }
  }

  @ViewBuilder private var upcomingSection: some View {
    if !upcomingTransactions.isEmpty {
      Section("Upcoming") {
        ForEach(upcomingTransactions) { entry in
          row(for: entry, isOverdue: false)
        }
      }
    }
  }

  @ViewBuilder
  private func row(for entry: TransactionWithBalance, isOverdue: Bool) -> some View {
    UpcomingTransactionRow(
      transaction: entry.transaction,
      accounts: accounts,
      categories: categories,
      earmarks: earmarks,
      displayAmount: entry.displayAmount,
      isOverdue: isOverdue,
      isDueToday: isOverdue ? false : isDueToday(entry.transaction),
      onPay: { Task { await payTransaction(entry.transaction) } }
    )
    .tag(entry.transaction)
    .contextMenu { rowContextMenu(for: entry.transaction) }
    .swipeActions(edge: .trailing) {
      Button(role: .destructive) {
        transactionPendingDelete = entry.transaction.id
      } label: {
        Label("Delete Transaction", systemImage: "trash")
      }
    }
    .swipeActions(edge: .leading) {
      Button {
        Task { await payTransaction(entry.transaction) }
      } label: {
        Label("Pay Scheduled Transaction", systemImage: "checkmark.circle")
      }
      .tint(.green)
    }
  }

  @ViewBuilder
  private func rowContextMenu(for transaction: Transaction) -> some View {
    Button("Pay Scheduled Transaction", systemImage: "checkmark.circle") {
      Task { await payTransaction(transaction) }
    }
    Button("Edit Transaction\u{2026}", systemImage: "pencil") {
      selectedTransaction = transaction
    }
    Divider()
    Button("Delete Transaction\u{2026}", systemImage: "trash", role: .destructive) {
      transactionPendingDelete = transaction.id
    }
  }

  private func createNewScheduledTransaction() {
    let instrument = accounts.ordered.first?.instrument ?? .AUD
    let fallbackAccountId = accounts.ordered.first?.id

    // Build the placeholder with its own UUID and persist that exact
    // transaction — CloudKit's repository echoes the input, so
    // `selectedTransaction.id` stays stable through the create and the
    // inspector doesn't recreate its detail view (preserves focus state).
    let placeholder: Transaction? = fallbackAccountId.map { id in
      Transaction(
        date: Date(),
        payee: "",
        recurPeriod: .month,
        recurEvery: 1,
        legs: [TransactionLeg(accountId: id, instrument: instrument, quantity: 0, type: .expense)]
      )
    }
    selectedTransaction = placeholder
    guard let placeholder else { return }
    Task {
      _ = await transactionStore.create(placeholder)
    }
  }

  private var overdueTransactions: [TransactionWithBalance] {
    transactionStore.scheduledOverdueTransactions
  }

  private var upcomingTransactions: [TransactionWithBalance] {
    transactionStore.scheduledUpcomingTransactions
  }

  private func isDueToday(_ transaction: Transaction) -> Bool {
    Calendar.current.isDateInToday(transaction.date)
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
  backend: CloudKitBackend,
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
