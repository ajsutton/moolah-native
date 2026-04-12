import SwiftUI

struct EarmarkBudgetSectionView: View {
  let earmark: Earmark
  let categories: Categories
  let analysisRepository: AnalysisRepository
  @Environment(EarmarkStore.self) private var earmarkStore

  @State private var categoryBalances: [UUID: InstrumentAmount] = [:]
  @State private var isLoadingBalances = false
  @State private var showAddSheet = false
  @State private var editingLineItem: BudgetLineItem?
  @State private var deleteConfirmation: BudgetLineItem?

  var body: some View {
    Group {
      if earmarkStore.isBudgetLoading || isLoadingBalances {
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if lineItems.isEmpty && earmarkStore.budgetItems.isEmpty {
        ContentUnavailableView(
          "No Budget",
          systemImage: "bookmark",
          description: Text("Add budget allocations to categories")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        budgetList
      }
    }
    .task(id: earmark.id) {
      await loadData()
    }
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          showAddSheet = true
        } label: {
          Label("Add Budget Line Item", systemImage: "plus")
        }
        .accessibilityLabel("Add budget line item")
      }
    }
    .sheet(isPresented: $showAddSheet) {
      AddBudgetLineItemSheet(
        earmark: earmark,
        categories: categories,
        existingCategoryIds: Set(earmarkStore.budgetItems.map(\.categoryId))
      )
    }
    .sheet(item: $editingLineItem) { lineItem in
      EditBudgetAmountSheet(
        earmark: earmark,
        lineItem: lineItem
      )
    }
    .confirmationDialog(
      "Delete Budget Item",
      isPresented: Binding(
        get: { deleteConfirmation != nil },
        set: { if !$0 { deleteConfirmation = nil } }
      ),
      presenting: deleteConfirmation
    ) { item in
      Button("Delete", role: .destructive) {
        Task {
          await earmarkStore.removeBudgetItem(
            earmarkId: earmark.id, categoryId: item.id)
        }
      }
    } message: { item in
      Text("Remove \(item.categoryName) from the budget?")
    }
    .refreshable {
      await loadData()
    }
  }

  private var lineItems: [BudgetLineItem] {
    BudgetLineItem.buildLineItems(
      budgetItems: earmarkStore.budgetItems,
      categoryBalances: categoryBalances,
      categories: categories
    )
  }

  private var totalActual: InstrumentAmount {
    lineItems.reduce(.zero(instrument: lineItems.first?.actual.instrument ?? .AUD)) {
      $0 + $1.actual
    }
  }

  private var totalBudgeted: InstrumentAmount {
    lineItems.reduce(.zero(instrument: lineItems.first?.budgeted.instrument ?? .AUD)) {
      $0 + $1.budgeted
    }
  }

  private var totalRemaining: InstrumentAmount {
    totalBudgeted + totalActual
  }

  private var unallocated: InstrumentAmount? {
    BudgetLineItem.unallocatedAmount(
      budgetItems: earmarkStore.budgetItems,
      savingsGoal: earmark.savingsGoal
    )
  }

  private var budgetList: some View {
    List {
      Section {
        headerRow
          .listRowBackground(Color.clear)

        ForEach(lineItems) { lineItem in
          budgetRow(lineItem)
        }
        .onDelete { offsets in
          deleteBudgetItems(at: offsets)
        }
      }

      Section {
        totalRow

        if let unallocated {
          unallocatedRow(unallocated)
        }
      }
    }
    #if os(macOS)
      .listStyle(.inset)
    #else
      .listStyle(.plain)
    #endif
  }

  private var headerRow: some View {
    HStack(spacing: 0) {
      Text("Category")
        .frame(maxWidth: .infinity, alignment: .leading)
      Text("Actual")
        .frame(minWidth: 70, idealWidth: 90, alignment: .trailing)
      Text("Budget")
        .frame(minWidth: 70, idealWidth: 90, alignment: .trailing)
      Text("Remaining")
        .frame(minWidth: 70, idealWidth: 90, alignment: .trailing)
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .accessibilityAddTraits(.isHeader)
  }

  private func budgetRow(_ lineItem: BudgetLineItem) -> some View {
    HStack(spacing: 0) {
      Text(lineItem.categoryName)
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(.body)

      MonetaryAmountView(amount: lineItem.actual)
        .font(.body)
        .frame(minWidth: 70, idealWidth: 90, alignment: .trailing)

      Button {
        editingLineItem = lineItem
      } label: {
        MonetaryAmountView(amount: lineItem.budgeted, colorOverride: .primary)
          .font(.body)
          .frame(minWidth: 70, idealWidth: 90, alignment: .trailing)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Edit budget for \(lineItem.categoryName)")

      MonetaryAmountView(amount: lineItem.remaining)
        .font(.body)
        .frame(minWidth: 70, idealWidth: 90, alignment: .trailing)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "\(lineItem.categoryName): spent \(lineItem.actual.formatted), budget \(lineItem.budgeted.formatted), remaining \(lineItem.remaining.formatted)"
    )
  }

  private var totalRow: some View {
    HStack(spacing: 0) {
      Text("Total")
        .font(.headline)
        .frame(maxWidth: .infinity, alignment: .leading)

      MonetaryAmountView(amount: totalActual)
        .font(.headline)
        .frame(minWidth: 70, idealWidth: 90, alignment: .trailing)

      MonetaryAmountView(amount: totalBudgeted, colorOverride: .primary)
        .font(.headline)
        .frame(minWidth: 70, idealWidth: 90, alignment: .trailing)

      MonetaryAmountView(amount: totalRemaining)
        .font(.headline)
        .frame(minWidth: 70, idealWidth: 90, alignment: .trailing)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "Total: spent \(totalActual.formatted), budget \(totalBudgeted.formatted), remaining \(totalRemaining.formatted)"
    )
  }

  private func unallocatedRow(_ amount: InstrumentAmount) -> some View {
    HStack(spacing: 0) {
      Text("Unallocated")
        .font(.body)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)

      Spacer()
        .frame(minWidth: 70, idealWidth: 90)

      MonetaryAmountView(amount: amount)
        .font(.body)
        .frame(minWidth: 70, idealWidth: 90, alignment: .trailing)

      MonetaryAmountView(amount: amount)
        .font(.body)
        .frame(minWidth: 70, idealWidth: 90, alignment: .trailing)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Unallocated: \(amount.formatted)")
  }

  private func loadData() async {
    isLoadingBalances = true
    async let budgetLoad: () = earmarkStore.loadBudget(earmarkId: earmark.id)
    async let balancesLoad: () = loadCategoryBalances()
    _ = await (budgetLoad, balancesLoad)
    isLoadingBalances = false
  }

  private func loadCategoryBalances() async {
    let distantPast = Date.distantPast
    let now = Date()
    do {
      categoryBalances = try await analysisRepository.fetchCategoryBalances(
        dateRange: distantPast...now,
        transactionType: .expense,
        filters: TransactionFilter(earmarkId: earmark.id)
      )
    } catch {
      categoryBalances = [:]
    }
  }

  private func deleteBudgetItems(at offsets: IndexSet) {
    let items = lineItems
    // Use confirmation for first item; swipe-delete only allows single items
    if let first = offsets.first {
      deleteConfirmation = items[first]
    }
  }
}
