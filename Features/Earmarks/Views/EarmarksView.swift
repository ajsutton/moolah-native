import SwiftUI

struct EarmarksView: View {
  let earmarkStore: EarmarkStore
  let accounts: Accounts
  let categories: Categories
  let transactionStore: TransactionStore
  let analysisRepository: AnalysisRepository

  @State private var showCreateSheet = false
  @State private var selectedEarmark: Earmark?
  @State private var earmarkToEdit: Earmark?
  @State private var searchText = ""

  var body: some View {
    Group {
      #if os(macOS)
        HStack(spacing: 0) {
          listView

          if let selected = selectedEarmark {
            Divider()

            EarmarkDetailView(
              earmark: selected,
              accounts: accounts,
              categories: categories,
              earmarks: earmarkStore.earmarks,
              transactionStore: transactionStore,
              analysisRepository: analysisRepository
            )
          }
        }
      #else
        listView
          .sheet(item: $selectedEarmark) { selected in
            NavigationStack {
              EarmarkDetailView(
                earmark: selected,
                accounts: accounts,
                categories: categories,
                earmarks: earmarkStore.earmarks,
                transactionStore: transactionStore,
                analysisRepository: analysisRepository
              )
              .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                  Button("Done") {
                    selectedEarmark = nil
                  }
                }
              }
            }
          }
      #endif
    }
    .sheet(isPresented: $showCreateSheet) {
      CreateEarmarkSheet(
        currency: earmarkStore.totalBalance.currency,
        onCreate: { newEarmark in
          Task {
            _ = await earmarkStore.create(newEarmark)
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
            _ = await earmarkStore.update(updated)
            selectedEarmark = updated
            earmarkToEdit = nil
          }
        }
      )
    }
  }

  private var filteredEarmarks: [Earmark] {
    if searchText.isEmpty {
      return earmarkStore.earmarks.ordered
    }
    return earmarkStore.earmarks.ordered.filter {
      $0.name.localizedCaseInsensitiveContains(searchText)
    }
  }

  private var listView: some View {
    List(selection: $selectedEarmark) {
      ForEach(filteredEarmarks) { earmark in
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
              Image(systemName: "arrow.up")
                .foregroundStyle(.green)
            }
            .font(.caption)

            Label {
              MonetaryAmountView(amount: earmark.spent, font: .caption)
            } icon: {
              Image(systemName: "arrow.down")
                .foregroundStyle(.red)
            }
            .font(.caption)
          }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
          "\(earmark.name), balance \(earmark.balance.decimalValue.formatted(.currency(code: earmark.balance.currency.code)))"
        )
        .tag(earmark)
        .contextMenu {
          Button("Edit", systemImage: "pencil") {
            earmarkToEdit = earmark
          }
          Divider()
          Button("Hide", systemImage: "eye.slash", role: .destructive) {
            Task {
              var hidden = earmark
              hidden.isHidden = true
              _ = await earmarkStore.update(hidden)
            }
          }
        }
        .swipeActions(edge: .trailing) {
          Button(role: .destructive) {
            Task {
              var hidden = earmark
              hidden.isHidden = true
              _ = await earmarkStore.update(hidden)
            }
          } label: {
            Label("Hide", systemImage: "eye.slash")
          }
        }
        .swipeActions(edge: .leading) {
          Button {
            earmarkToEdit = earmark
          } label: {
            Label("Edit", systemImage: "pencil")
          }
          .tint(.blue)
        }
      }
    }
    #if os(macOS)
      .listStyle(.inset)
    #else
      .listStyle(.plain)
    #endif
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
    .searchable(text: $searchText, prompt: "Search earmarks")
    .overlay {
      if earmarkStore.isLoading && earmarkStore.earmarks.ordered.isEmpty {
        ProgressView()
      } else if !earmarkStore.isLoading && earmarkStore.earmarks.ordered.isEmpty {
        ContentUnavailableView(
          "No Earmarks",
          systemImage: "bookmark.fill",
          description: Text("Create an earmark to start tracking savings goals.")
        )
      }
    }
  }
}

private struct CreateEarmarkSheet: View {
  let currency: Currency
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
    let goalCents = MonetaryAmount.parseCents(from: savingsGoal)
    let goal =
      goalCents > 0 ? MonetaryAmount(cents: goalCents, currency: currency) : nil

    let newEarmark = Earmark(
      name: name,
      savingsGoal: goal,
      savingsStartDate: useDateRange ? startDate : nil,
      savingsEndDate: useDateRange ? endDate : nil
    )
    onCreate(newEarmark)
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
    let goalCents = MonetaryAmount.parseCents(from: savingsGoal)
    let goal =
      goalCents > 0 ? MonetaryAmount(cents: goalCents, currency: earmark.balance.currency) : nil

    var updated = earmark
    updated.name = name
    updated.savingsGoal = goal
    updated.savingsStartDate = useDateRange ? startDate : nil
    updated.savingsEndDate = useDateRange ? endDate : nil
    updated.isHidden = isHidden

    onUpdate(updated)
  }

}

#Preview {
  let repository = InMemoryEarmarkRepository(initialEarmarks: [
    Earmark(
      name: "Holiday Fund",
      balance: MonetaryAmount(cents: 150000, currency: Currency.AUD),
      saved: MonetaryAmount(cents: 200000, currency: Currency.AUD),
      spent: MonetaryAmount(cents: 50000, currency: Currency.AUD),
      savingsGoal: MonetaryAmount(cents: 500000, currency: Currency.AUD)
    ),
    Earmark(
      name: "Emergency Fund",
      balance: MonetaryAmount(cents: 300000, currency: Currency.AUD),
      saved: MonetaryAmount(cents: 300000, currency: Currency.AUD)
    ),
  ])

  let earmarkStore = EarmarkStore(repository: repository)
  let transactionStore = TransactionStore(repository: InMemoryTransactionRepository())

  NavigationStack {
    EarmarksView(
      earmarkStore: earmarkStore,
      accounts: Accounts(from: []),
      categories: Categories(from: []),
      transactionStore: transactionStore,
      analysisRepository: InMemoryBackend().analysis
    )
  }
  .task { await earmarkStore.load() }
}
