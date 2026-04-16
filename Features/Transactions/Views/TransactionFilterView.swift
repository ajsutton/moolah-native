import SwiftUI

struct TransactionFilterView: View {
  let filter: TransactionFilter
  let accounts: Accounts
  let categories: Categories
  let earmarks: Earmarks
  let onApply: (TransactionFilter) -> Void

  @State private var selectedAccountId: UUID?
  @State private var selectedEarmarkId: UUID?
  @State private var selectedScheduled: Bool?
  @State private var dateRangeLowerBound: Date?
  @State private var dateRangeUpperBound: Date?
  @State private var selectedCategoryIds: Set<UUID> = []
  @State private var payeeText: String = ""

  @Environment(\.dismiss) private var dismiss

  init(
    filter: TransactionFilter,
    accounts: Accounts,
    categories: Categories,
    earmarks: Earmarks,
    onApply: @escaping (TransactionFilter) -> Void
  ) {
    self.filter = filter
    self.accounts = accounts
    self.categories = categories
    self.earmarks = earmarks
    self.onApply = onApply

    _selectedAccountId = State(initialValue: filter.accountId)
    _selectedEarmarkId = State(initialValue: filter.earmarkId)
    _selectedScheduled = State(initialValue: filter.scheduled)
    _dateRangeLowerBound = State(initialValue: filter.dateRange?.lowerBound)
    _dateRangeUpperBound = State(initialValue: filter.dateRange?.upperBound)
    _selectedCategoryIds = State(initialValue: filter.categoryIds ?? [])
    _payeeText = State(initialValue: filter.payee ?? "")
  }

  private var allCategories: [Category] {
    var result: [Category] = []
    for root in categories.roots {
      result.append(root)
      result.append(contentsOf: categories.children(of: root.id))
    }
    return result
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Date Range") {
          Toggle(
            "Filter by date",
            isOn: Binding(
              get: { dateRangeLowerBound != nil && dateRangeUpperBound != nil },
              set: { enabled in
                if enabled {
                  let now = Date()
                  let calendar = Calendar.current
                  dateRangeLowerBound = calendar.date(byAdding: .month, value: -1, to: now)
                  dateRangeUpperBound = now
                } else {
                  dateRangeLowerBound = nil
                  dateRangeUpperBound = nil
                }
              }
            ))

          if dateRangeLowerBound != nil && dateRangeUpperBound != nil {
            DatePicker(
              "Start Date",
              selection: Binding(
                get: { dateRangeLowerBound ?? Date() },
                set: { dateRangeLowerBound = $0 }
              ),
              displayedComponents: .date
            )

            DatePicker(
              "End Date",
              selection: Binding(
                get: { dateRangeUpperBound ?? Date() },
                set: { dateRangeUpperBound = $0 }
              ),
              displayedComponents: .date
            )
          }
        }

        Section("Account") {
          Picker("Account", selection: $selectedAccountId) {
            Text("All Accounts").tag(nil as UUID?)
            ForEach(accounts.ordered) { account in
              Text(account.name).tag(account.id as UUID?)
            }
          }
        }

        Section("Earmark") {
          Picker("Earmark", selection: $selectedEarmarkId) {
            Text("All Earmarks").tag(nil as UUID?)
            ForEach(earmarks.ordered) { earmark in
              Text(earmark.name).tag(earmark.id as UUID?)
            }
          }
        }

        Section("Categories") {
          if categories.roots.isEmpty {
            Text("No categories available")
              .foregroundStyle(.secondary)
          } else {
            ForEach(allCategories) { category in
              Toggle(
                category.name,
                isOn: Binding(
                  get: { selectedCategoryIds.contains(category.id) },
                  set: { isOn in
                    if isOn {
                      selectedCategoryIds.insert(category.id)
                    } else {
                      selectedCategoryIds.remove(category.id)
                    }
                  }
                ))
            }
          }
        }

        Section("Payee") {
          TextField("Payee contains…", text: $payeeText)
        }

        Section("Scheduled") {
          Picker("Scheduled", selection: $selectedScheduled) {
            Text("All Transactions").tag(nil as Bool?)
            Text("Scheduled Only").tag(true as Bool?)
            Text("Non-Scheduled Only").tag(false as Bool?)
          }
        }
      }
      .navigationTitle("Filter Transactions")
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
          Button("Apply") {
            applyFilter()
          }
        }

        #if os(iOS)
          ToolbarItem(placement: .bottomBar) {
            Button("Clear All") {
              clearAll()
            }
          }
        #else
          ToolbarItem(placement: .automatic) {
            Button("Clear All") {
              clearAll()
            }
            .keyboardShortcut(.delete, modifiers: .command)
          }
        #endif
      }
    }
  }

  private func applyFilter() {
    var dateRange: ClosedRange<Date>?
    if let lower = dateRangeLowerBound, let upper = dateRangeUpperBound {
      dateRange = lower...upper
    }

    let newFilter = TransactionFilter(
      accountId: selectedAccountId,
      earmarkId: selectedEarmarkId,
      scheduled: selectedScheduled,
      dateRange: dateRange,
      categoryIds: selectedCategoryIds.isEmpty ? nil : selectedCategoryIds,
      payee: payeeText.isEmpty ? nil : payeeText
    )

    onApply(newFilter)
  }

  private func clearAll() {
    selectedAccountId = nil
    selectedEarmarkId = nil
    selectedScheduled = nil
    dateRangeLowerBound = nil
    dateRangeUpperBound = nil
    selectedCategoryIds = []
    payeeText = ""
  }
}

#Preview {
  let accountId = UUID()
  let categoryId = UUID()
  let earmarkId = UUID()

  let accounts = Accounts(from: [
    Account(
      id: accountId, name: "Checking", type: .bank,
      positions: [Position(instrument: .AUD, quantity: 2449.77)]
    )
  ])

  let categories = Categories(from: [
    Category(id: categoryId, name: "Groceries", parentId: nil),
    Category(id: UUID(), name: "Transport", parentId: nil),
  ])

  let earmarks = Earmarks(from: [
    Earmark(
      id: earmarkId, name: "Emergency Fund"
    )
  ])

  TransactionFilterView(
    filter: TransactionFilter(),
    accounts: accounts,
    categories: categories,
    earmarks: earmarks,
    onApply: { _ in }
  )
}
