import SwiftData
import SwiftUI

struct EarmarkDetailView: View {
  private enum DetailTab: String, CaseIterable {
    case transactions = "Transactions"
    case budget = "Budget"
  }

  let earmark: Earmark
  let accounts: Accounts
  let categories: Categories
  let earmarks: Earmarks
  let transactionStore: TransactionStore
  let analysisRepository: AnalysisRepository
  @State private var showEditSheet = false
  @State private var selectedTab: DetailTab = .transactions
  @State private var selectedTransaction: Transaction?
  @Environment(EarmarkStore.self) private var earmarkStore

  var body: some View {
    VStack(spacing: 0) {
      overviewPanel
      Divider()

      Picker("View", selection: $selectedTab) {
        ForEach(DetailTab.allCases, id: \.self) { tab in
          Text(tab.rawValue).tag(tab)
        }
      }
      .pickerStyle(.segmented)
      .padding(.horizontal)
      .padding(.vertical, 8)

      switch selectedTab {
      case .transactions:
        TransactionListView(
          title: earmark.name,
          filter: TransactionFilter(earmarkId: earmark.id),
          accounts: accounts,
          categories: categories,
          earmarks: earmarks,
          transactionStore: transactionStore,
          selectedTransaction: $selectedTransaction
        )
      case .budget:
        EarmarkBudgetSectionView(
          earmark: earmark,
          categories: categories,
          analysisRepository: analysisRepository
        )
      }
    }
    .transactionInspector(
      selectedTransaction: $selectedTransaction,
      accounts: accounts,
      categories: categories,
      earmarks: earmarks,
      transactionStore: transactionStore
    )
    .profileNavigationTitle(earmark.name)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          showEditSheet = true
        } label: {
          Label("Edit", systemImage: "pencil")
        }
      }
    }
    .sheet(isPresented: $showEditSheet) {
      EditEarmarkSheet(
        earmark: earmark,
        onUpdate: { updated in
          Task {
            _ = await earmarkStore.update(updated)
            showEditSheet = false
          }
        }
      )
    }
  }

  private var overviewPanel: some View {
    VStack(spacing: 12) {
      HStack(spacing: 24) {
        summaryItem(label: "Balance", amount: earmark.balance)
        Divider().frame(maxHeight: 32)
        summaryItem(label: "Saved", amount: earmark.saved)
        Divider().frame(maxHeight: 32)
        summaryItem(label: "Spent", amount: earmark.spent)
      }

      if let goal = earmark.savingsGoal, goal.isPositive {
        VStack(spacing: 4) {
          let progress =
            earmark.balance.isPositive
            ? Double(truncating: (earmark.balance.quantity / goal.quantity) as NSDecimalNumber)
            : 0.0

          ProgressView(value: min(progress, 1.0)) {
            HStack {
              Text("Savings Goal")
                .font(.caption)
              Spacer()
              InstrumentAmountView(amount: earmark.balance)
                .font(.caption)
              Text("of")
                .font(.caption)
                .foregroundStyle(.secondary)
              InstrumentAmountView(amount: goal)
                .font(.caption)
            }
          }
          .tint(progress >= 1.0 ? .green : .blue)

          savingsDateRow
        }
      }
    }
    .padding()
  }

  private func summaryItem(label: String, amount: InstrumentAmount) -> some View {
    VStack(spacing: 2) {
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
      InstrumentAmountView(amount: amount)
        .font(.headline)
    }
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder
  private var savingsDateRow: some View {
    let hasStart = earmark.savingsStartDate != nil
    let hasEnd = earmark.savingsEndDate != nil

    if hasStart || hasEnd {
      HStack {
        if let start = earmark.savingsStartDate {
          Label(start.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if hasStart && hasEnd {
          Image(systemName: "arrow.right")
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }

        if let end = earmark.savingsEndDate {
          Label(end.formatted(date: .abbreviated, time: .omitted), systemImage: "flag")
            .font(.caption)
            .foregroundStyle(.secondary)

          if let remaining = timeRemaining(until: end) {
            Spacer()
            Text(remaining)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        if !hasEnd {
          Spacer()
        }
      }
    }
  }

  private func timeRemaining(until endDate: Date) -> String? {
    let now = Date()
    guard endDate > now else { return "Past due" }

    let components = Calendar.current.dateComponents([.day], from: now, to: endDate)
    guard let days = components.day else { return nil }

    if days == 0 { return "Due today" }
    if days == 1 { return "1 day left" }
    if days < 30 { return "\(days) days left" }
    let months = days / 30
    if months == 1 { return "~1 month left" }
    return "~\(months) months left"
  }
}

#Preview {
  let earmarkId = UUID()
  let earmark = Earmark(
    id: earmarkId,
    name: "Holiday Fund",
    balance: InstrumentAmount(quantity: 2500, instrument: .AUD),
    saved: InstrumentAmount(quantity: 3000, instrument: .AUD),
    spent: InstrumentAmount(quantity: 500, instrument: .AUD),
    savingsGoal: InstrumentAmount(quantity: 5000, instrument: .AUD),
    savingsStartDate: Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 1)),
    savingsEndDate: Calendar.current.date(from: DateComponents(year: 2026, month: 12, day: 31))
  )
  let (backend, _) = PreviewBackend.create()
  let earmarkStore = EarmarkStore(repository: backend.earmarks)
  let store = TransactionStore(repository: backend.transactions)

  NavigationStack {
    EarmarkDetailView(
      earmark: earmark,
      accounts: Accounts(from: []),
      categories: Categories(from: []),
      earmarks: Earmarks(from: []),
      transactionStore: store,
      analysisRepository: backend.analysis
    )
    .environment(earmarkStore)
  }
  .task {
    let accountId = UUID()
    _ = try? await backend.accounts.create(
      Account(id: accountId, name: "Test", type: .bank))
    _ = try? await backend.earmarks.create(earmark)
    _ = try? await backend.transactions.create(
      Transaction(
        date: Date(), payee: "Flight Booking",
        legs: [
          TransactionLeg(
            accountId: accountId, instrument: .AUD, quantity: -50.23, type: .expense,
            earmarkId: earmarkId)
        ]))
    _ = try? await backend.transactions.create(
      Transaction(
        date: Date().addingTimeInterval(-86400), payee: "Savings Transfer",
        legs: [
          TransactionLeg(
            accountId: accountId, instrument: .AUD, quantity: 500, type: .income,
            earmarkId: earmarkId)
        ]))
    await earmarkStore.load()
    await store.load(filter: TransactionFilter(earmarkId: earmarkId))
  }
}
