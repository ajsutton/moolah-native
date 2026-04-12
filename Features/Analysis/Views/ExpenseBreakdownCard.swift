import Charts
import SwiftUI

struct ExpenseBreakdownCard: View {
  let breakdown: [ExpenseBreakdown]
  let categories: Categories

  @State private var selectedCategoryId: UUID? = nil

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Expenses by Category")
        .font(.title2)
        .fontWeight(.semibold)

      if filteredBreakdown.isEmpty {
        emptyState
      } else {
        ExpandableChart(title: "Expenses by Category") {
          pieChart
        }
        legendGrid
        breadcrumbs
      }
    }
    .padding()
    #if os(macOS)
      .background(Color(nsColor: .controlBackgroundColor))
    #else
      .background(Color(uiColor: .systemBackground))
    #endif
    .cornerRadius(12)
  }

  private var emptyState: some View {
    Text("No expense data")
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .center)
      .padding(.vertical, 40)
  }

  private var pieChart: some View {
    Chart(filteredBreakdown, id: \.categoryId) { item in
      SectorMark(
        angle: .value("Amount", Double(truncating: item.totalExpenses.quantity as NSDecimalNumber)),
        innerRadius: .ratio(0.5),
        angularInset: 1.5
      )
      .foregroundStyle(by: .value("Category", categoryName(for: item.categoryId)))
      .annotation(position: .overlay) {
        if item.percentage > 5 {  // Only show label if >5%
          Text("\(Int(item.percentage))%")
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.white)
        }
      }
    }
    .frame(height: 250)
    .accessibilityLabel("Expense breakdown pie chart")
  }

  private var legendGrid: some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: 8) {
      ForEach(filteredBreakdown, id: \.categoryId) { item in
        Button {
          handleCategoryTap(item.categoryId)
        } label: {
          HStack {
            Circle()
              .fill(categoryColor(for: item.categoryId))
              .frame(width: 12, height: 12)
            Text(categoryName(for: item.categoryId))
              .font(.caption)
              .foregroundStyle(.primary)
            Spacer()
            Text(item.totalExpenses.formatted)
              .font(.caption)
              .monospacedDigit()
              .foregroundStyle(.secondary)
          }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
          "\(categoryName(for: item.categoryId)): \(item.totalExpenses.formatted)"
        )
        .accessibilityHint(hasChildren(item.categoryId) ? "Double tap to drill down" : "")
      }
    }
  }

  private var breadcrumbs: some View {
    Group {
      if selectedCategoryId != nil {
        HStack {
          Button("All Categories") {
            selectedCategoryId = nil
          }
          .font(.caption)
          .foregroundStyle(.blue)
        }
      }
    }
  }

  private var filteredBreakdown: [ExpenseBreakdownWithPercentage] {
    // Sum all expenses for this category level, negated to positive for display
    // (server returns negative amounts for expenses)
    let categoryTotals = Dictionary(grouping: breakdown) { $0.categoryId }
      .mapValues { items -> InstrumentAmount in
        let sum = items.reduce(
          InstrumentAmount.zero(instrument: items.first!.totalExpenses.instrument)
        ) {
          $0 + $1.totalExpenses
        }
        let negated = InstrumentAmount(quantity: max(0, -sum.quantity), instrument: sum.instrument)
        return negated
      }

    // Filter by selectedCategoryId (show only children if drill-down active)
    let visibleCategories: [UUID?]
    if let selectedId = selectedCategoryId {
      let children = categories.children(of: selectedId)
        .map { $0.id as UUID? }
      visibleCategories = children
    } else {
      // Show top-level categories (no parent)
      visibleCategories =
        categories.roots
        .map { $0.id as UUID? }
        + [nil]  // Include uncategorized
    }

    let filtered = categoryTotals.filter { visibleCategories.contains($0.key) }
    let total = filtered.values.reduce(
      .zero(instrument: filtered.values.first?.instrument ?? .AUD), +)

    return filtered.map { categoryId, amount in
      ExpenseBreakdownWithPercentage(
        categoryId: categoryId,
        totalExpenses: amount,
        percentage: total.quantity > 0
          ? Double(truncating: (amount.quantity / total.quantity * 100) as NSDecimalNumber) : 0
      )
    }
    .sorted { $0.totalExpenses.quantity > $1.totalExpenses.quantity }
  }

  private func categoryName(for id: UUID?) -> String {
    guard let id = id else { return "Uncategorized" }
    return categories.by(id: id)?.name ?? "Unknown"
  }

  /// Fixed palette of system-compatible colors for chart segments.
  private static let chartPalette: [Color] = [
    .blue, .green, .orange, .purple, .red, .teal, .indigo, .pink, .mint, .cyan, .brown, .yellow,
  ]

  private func categoryColor(for id: UUID?) -> Color {
    guard let id = id else { return .gray }
    let index = abs(id.hashValue) % Self.chartPalette.count
    return Self.chartPalette[index]
  }

  private func hasChildren(_ categoryId: UUID?) -> Bool {
    guard let categoryId = categoryId else { return false }
    return !categories.children(of: categoryId).isEmpty
  }

  private func handleCategoryTap(_ categoryId: UUID?) {
    if hasChildren(categoryId) {
      selectedCategoryId = categoryId
    }
  }
}

struct ExpenseBreakdownWithPercentage: Identifiable {
  let categoryId: UUID?
  let totalExpenses: InstrumentAmount
  let percentage: Double

  var id: String {
    categoryId?.uuidString ?? "uncategorized"
  }
}

#Preview {
  let categories = [
    Category(id: UUID(), name: "Groceries"),
    Category(id: UUID(), name: "Transport"),
    Category(id: UUID(), name: "Entertainment"),
  ]

  let breakdown = [
    ExpenseBreakdown(
      categoryId: categories[0].id,
      month: "202604",
      totalExpenses: InstrumentAmount(quantity: 450, instrument: .AUD)
    ),
    ExpenseBreakdown(
      categoryId: categories[1].id,
      month: "202604",
      totalExpenses: InstrumentAmount(quantity: 250, instrument: .AUD)
    ),
    ExpenseBreakdown(
      categoryId: categories[2].id,
      month: "202604",
      totalExpenses: InstrumentAmount(quantity: 150, instrument: .AUD)
    ),
  ]

  ExpenseBreakdownCard(breakdown: breakdown, categories: Categories(from: categories))
    .frame(width: 400)
    .padding()
}
