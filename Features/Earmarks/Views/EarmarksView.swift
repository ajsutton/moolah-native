import SwiftUI

struct EarmarksView: View {
  let earmarkStore: EarmarkStore
  let accounts: Accounts
  let categories: Categories
  let transactionStore: TransactionStore

  @State private var showCreateSheet = false
  @State private var selectedEarmark: Earmark?
  @State private var earmarkToEdit: Earmark?

  var body: some View {
    HStack(spacing: 0) {
      listView

      if let selected = selectedEarmark {
        Divider()

        EarmarkDetailView(
          earmark: selected,
          accounts: accounts,
          categories: categories,
          earmarks: earmarkStore.earmarks,
          transactionStore: transactionStore
        )
      }
    }
    .sheet(isPresented: $showCreateSheet) {
      CreateEarmarkSheet(
        onCreate: { newEarmark in
          Task {
            await earmarkStore.create(newEarmark)
            showCreateSheet = false
          }
        }
      )
    }
    .sheet(item: $earmarkToEdit) { earmark in
      EditEarmarkSheet(
        earmark: earmark,
        onUpdate: { updated in
          Task {
            await earmarkStore.update(updated)
            selectedEarmark = updated
            earmarkToEdit = nil
          }
        }
      )
    }
  }

  private var listView: some View {
    List(selection: $selectedEarmark) {
      ForEach(earmarkStore.earmarks.ordered) { earmark in
        VStack(alignment: .leading, spacing: 4) {
          HStack {
            Text(earmark.name)
              .font(.headline)
            Spacer()
            MonetaryAmountView(amount: earmark.balance, font: .headline)
          }

          HStack(spacing: 12) {
            Label {
              MonetaryAmountView(amount: earmark.saved, font: .caption)
            } icon: {
              Image(systemName: "arrow.down.circle")
                .foregroundStyle(.green)
            }
            .font(.caption)

            Label {
              MonetaryAmountView(amount: earmark.spent, font: .caption)
            } icon: {
              Image(systemName: "arrow.up.circle")
                .foregroundStyle(.red)
            }
            .font(.caption)
          }
        }
        .tag(earmark)
        .contextMenu {
          Button {
            earmarkToEdit = earmark
          } label: {
            Label("Edit", systemImage: "pencil")
          }
        }
      }
    }
    .navigationTitle("Earmarks")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          showCreateSheet = true
        } label: {
          Label("Add Earmark", systemImage: "plus")
        }
      }
    }
    .task {
      await earmarkStore.load()
    }
    .refreshable {
      await earmarkStore.load()
    }
    .overlay {
      if earmarkStore.isLoading && earmarkStore.earmarks.ordered.isEmpty {
        ProgressView()
      } else if !earmarkStore.isLoading && earmarkStore.earmarks.ordered.isEmpty {
        ContentUnavailableView(
          "No Earmarks",
          systemImage: "folder",
          description: Text("Create an earmark to start tracking savings goals.")
        )
      }
    }
  }
}

private struct CreateEarmarkSheet: View {
  let onCreate: (Earmark) -> Void

  @State private var name: String = ""
  @State private var savingsGoal: String = ""
  @State private var startDate: Date = Date()
  @State private var endDate: Date = Calendar.current.date(byAdding: .year, value: 1, to: Date())!
  @State private var useDateRange: Bool = false
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Form {
        Section("Details") {
          TextField("Name", text: $name)
        }

        Section("Savings Goal") {
          TextField("Goal Amount", text: $savingsGoal)
            #if os(iOS)
              .keyboardType(.decimalPad)
            #endif

          Toggle("Set Date Range", isOn: $useDateRange)

          if useDateRange {
            DatePicker("Start Date", selection: $startDate, displayedComponents: .date)
            DatePicker("End Date", selection: $endDate, displayedComponents: .date)
          }
        }
      }
      .navigationTitle("New Earmark")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            dismiss()
          }
        }

        ToolbarItem(placement: .primaryAction) {
          Button("Create") {
            createEarmark()
          }
          .disabled(name.isEmpty)
        }
      }
    }
  }

  private func createEarmark() {
    let goalCents = parseCurrency(savingsGoal)
    let goal =
      goalCents > 0 ? MonetaryAmount(cents: goalCents, currency: Currency.defaultCurrency) : nil

    let newEarmark = Earmark(
      name: name,
      savingsGoal: goal,
      savingsStartDate: useDateRange ? startDate : nil,
      savingsEndDate: useDateRange ? endDate : nil
    )
    onCreate(newEarmark)
  }

  private func parseCurrency(_ text: String) -> Int {
    let cleaned = text.replacingOccurrences(of: "[^0-9.]", with: "", options: .regularExpression)
    if let decimal = Decimal(string: cleaned) {
      return Int(truncating: (decimal * 100) as NSNumber)
    }
    return 0
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
          TextField("Goal Amount", text: $savingsGoal)
            #if os(iOS)
              .keyboardType(.decimalPad)
            #endif

          Toggle("Set Date Range", isOn: $useDateRange)

          if useDateRange {
            DatePicker("Start Date", selection: $startDate, displayedComponents: .date)
            DatePicker("End Date", selection: $endDate, displayedComponents: .date)
          }
        }

        Section("Current Values") {
          LabeledContent("Balance") {
            MonetaryAmountView(amount: earmark.balance)
          }
          LabeledContent("Saved") {
            MonetaryAmountView(amount: earmark.saved)
          }
          LabeledContent("Spent") {
            MonetaryAmountView(amount: earmark.spent)
          }
        }
      }
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

        ToolbarItem(placement: .primaryAction) {
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
  let repository = InMemoryEarmarkRepository(initialEarmarks: [
    Earmark(
      name: "Holiday Fund",
      balance: MonetaryAmount(cents: 150000, currency: Currency.defaultCurrency),
      saved: MonetaryAmount(cents: 200000, currency: Currency.defaultCurrency),
      spent: MonetaryAmount(cents: 50000, currency: Currency.defaultCurrency),
      savingsGoal: MonetaryAmount(cents: 500000, currency: Currency.defaultCurrency)
    ),
    Earmark(
      name: "Emergency Fund",
      balance: MonetaryAmount(cents: 300000, currency: Currency.defaultCurrency),
      saved: MonetaryAmount(cents: 300000, currency: Currency.defaultCurrency)
    ),
  ])

  let earmarkStore = EarmarkStore(repository: repository)
  let transactionStore = TransactionStore(repository: InMemoryTransactionRepository())

  NavigationStack {
    EarmarksView(
      earmarkStore: earmarkStore,
      accounts: Accounts(from: []),
      categories: Categories(from: []),
      transactionStore: transactionStore
    )
  }
  .task { await earmarkStore.load() }
}
