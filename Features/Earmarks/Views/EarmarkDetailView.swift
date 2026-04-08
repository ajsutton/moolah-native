import SwiftUI

struct EarmarkDetailView: View {
  let earmark: Earmark
  let accounts: Accounts
  let categories: Categories
  let earmarks: Earmarks
  let transactionStore: TransactionStore
  @State private var showEditSheet = false
  @Environment(EarmarkStore.self) private var earmarkStore

  var body: some View {
    VStack(spacing: 0) {
      overviewPanel
      Divider()
      TransactionListView(
        title: earmark.name,
        filter: TransactionFilter(earmarkId: earmark.id),
        accounts: accounts,
        categories: categories,
        earmarks: earmarks,
        transactionStore: transactionStore
      )
    }
    .navigationTitle(earmark.name)
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
            await earmarkStore.update(updated)
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
        Divider().frame(height: 32)
        summaryItem(label: "Saved", amount: earmark.saved)
        Divider().frame(height: 32)
        summaryItem(label: "Spent", amount: earmark.spent)
      }

      if let goal = earmark.savingsGoal, goal > .zero {
        VStack(spacing: 4) {
          let progress =
            earmark.balance.cents > 0
            ? Double(earmark.balance.cents) / Double(goal.cents)
            : 0.0

          ProgressView(value: min(progress, 1.0)) {
            HStack {
              Text("Savings Goal")
                .font(.caption)
              Spacer()
              MonetaryAmountView(amount: earmark.balance)
                .font(.caption)
              Text("of")
                .font(.caption)
                .foregroundStyle(.secondary)
              MonetaryAmountView(amount: goal)
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

  private func summaryItem(label: String, amount: MonetaryAmount) -> some View {
    VStack(spacing: 2) {
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
      MonetaryAmountView(amount: amount)
        .font(.headline)
    }
    .frame(maxWidth: .infinity)
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

private struct EditEarmarkSheet: View {
  let earmark: Earmark
  let onUpdate: (Earmark) -> Void

  @State private var name: String
  @State private var savingsGoal: String
  @State private var startDate: Date
  @State private var endDate: Date
  @State private var useDateRange: Bool
  @State private var isHidden: Bool
  @Environment(\.dismiss) private var dismiss

  init(earmark: Earmark, onUpdate: @escaping (Earmark) -> Void) {
    self.earmark = earmark
    self.onUpdate = onUpdate
    _name = State(initialValue: earmark.name)
    _savingsGoal = State(initialValue: earmark.savingsGoal?.decimalValue.description ?? "")
    _startDate = State(initialValue: earmark.savingsStartDate ?? Date())
    _endDate = State(
      initialValue: earmark.savingsEndDate ?? Calendar.current.date(
        byAdding: .year, value: 1, to: Date())!)
    _useDateRange = State(
      initialValue: earmark.savingsStartDate != nil || earmark.savingsEndDate != nil)
    _isHidden = State(initialValue: earmark.isHidden)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Details") {
          TextField("Name", text: $name)
          Toggle("Hidden", isOn: $isHidden)
        }

        Section("Savings Goal") {
          HStack {
            Text(Currency.defaultCurrency.code)
              .foregroundStyle(.secondary)
            TextField("Amount", text: $savingsGoal)
              #if os(iOS)
                .keyboardType(.decimalPad)
              #endif
          }

          Toggle("Set Date Range", isOn: $useDateRange)

          if useDateRange {
            DatePicker("Start Date", selection: $startDate, displayedComponents: .date)
            DatePicker("End Date", selection: $endDate, displayedComponents: .date)
          }
        }
      }
      .formStyle(.grouped)
      .navigationTitle("Edit Earmark")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            dismiss()
          }
        }

        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            saveChanges()
          }
          .disabled(name.isEmpty)
        }
      }
    }
  }

  private func saveChanges() {
    let goalCents = parseCurrency(savingsGoal)
    let goal =
      goalCents > 0 ? MonetaryAmount(cents: goalCents, currency: Currency.defaultCurrency) : nil

    var updated = earmark
    updated.name = name
    updated.savingsGoal = goal
    updated.savingsStartDate = useDateRange ? startDate : nil
    updated.savingsEndDate = useDateRange ? endDate : nil
    updated.isHidden = isHidden

    onUpdate(updated)
  }

  private func parseCurrency(_ text: String) -> Int {
    let cleaned = text.replacingOccurrences(of: "[^0-9.]", with: "", options: .regularExpression)
    if let decimal = Decimal(string: cleaned) {
      return Int(truncating: (decimal * 100) as NSNumber)
    }
    return 0
  }
}

#Preview {
  let earmarkId = UUID()
  let earmark = Earmark(
    id: earmarkId,
    name: "Holiday Fund",
    balance: MonetaryAmount(cents: 250000, currency: Currency.defaultCurrency),
    saved: MonetaryAmount(cents: 300000, currency: Currency.defaultCurrency),
    spent: MonetaryAmount(cents: -50000, currency: Currency.defaultCurrency),
    savingsGoal: MonetaryAmount(cents: 500000, currency: Currency.defaultCurrency),
    savingsStartDate: Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 1)),
    savingsEndDate: Calendar.current.date(from: DateComponents(year: 2026, month: 12, day: 31))
  )
  let earmarkRepository = InMemoryEarmarkRepository(initialEarmarks: [earmark])
  let earmarkStore = EarmarkStore(repository: earmarkRepository)
  let repository = InMemoryTransactionRepository(initialTransactions: [
    Transaction(
      type: .expense, date: Date(), accountId: UUID(),
      amount: MonetaryAmount(cents: -5023, currency: Currency.defaultCurrency),
      payee: "Flight Booking", earmarkId: earmarkId),
    Transaction(
      type: .income, date: Date().addingTimeInterval(-86400), accountId: UUID(),
      amount: MonetaryAmount(cents: 50000, currency: Currency.defaultCurrency),
      payee: "Savings Transfer", earmarkId: earmarkId),
  ])
  let store = TransactionStore(repository: repository)

  NavigationStack {
    EarmarkDetailView(
      earmark: earmark,
      accounts: Accounts(from: []),
      categories: Categories(from: []),
      earmarks: Earmarks(from: []),
      transactionStore: store
    )
    .environment(earmarkStore)
  }
}
