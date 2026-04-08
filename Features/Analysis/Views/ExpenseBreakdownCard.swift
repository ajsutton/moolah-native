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
        pieChart
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
        angle: .value("Amount", item.totalExpenses.cents),
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
              .frame(width: 10, height: 10)
            Text(categoryName(for: item.categoryId))
              .font(.caption)
              .foregroundStyle(.primary)
            Spacer()
            Text(item.totalExpenses.formatNoSymbol)
              .font(.caption)
              .monospacedDigit()
              .foregroundStyle(.secondary)
          }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
          "\(categoryName(for: item.categoryId)): \(item.totalExpenses.formatNoSymbol)"
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
    // Sum all expenses for this category level
    let categoryTotals = Dictionary(grouping: breakdown) { $0.categoryId }
      .mapValues { items in
        items.reduce(MonetaryAmount.zero) { $0 + $1.totalExpenses }
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
    let total = filtered.values.reduce(MonetaryAmount.zero, +)

    return filtered.map { categoryId, amount in
      ExpenseBreakdownWithPercentage(
        categoryId: categoryId,
        totalExpenses: amount,
        percentage: total.cents > 0 ? Double(amount.cents) / Double(total.cents) * 100 : 0
      )
    }
    .sorted { $0.totalExpenses.cents > $1.totalExpenses.cents }
  }

  private func categoryName(for id: UUID?) -> String {
    guard let id = id else { return "Uncategorized" }
    return categories.by(id: id)?.name ?? "Unknown"
  }

  private func categoryColor(for id: UUID?) -> Color {
    guard let id = id else { return .gray }
    // Generate consistent color from UUID
    let hash = id.uuidString.hashValue
    let r = Double((hash & 0xFF0000) >> 16) / 255.0
    let g = Double((hash & 0x00FF00) >> 8) / 255.0
    let b = Double(hash & 0x0000FF) / 255.0
    return Color(red: r, green: g, blue: b)
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
  let totalExpenses: MonetaryAmount
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
      totalExpenses: MonetaryAmount(cents: 45000, currency: .defaultCurrency)
    ),
    ExpenseBreakdown(
      categoryId: categories[1].id,
      month: "202604",
      totalExpenses: MonetaryAmount(cents: 25000, currency: .defaultCurrency)
    ),
    ExpenseBreakdown(
      categoryId: categories[2].id,
      month: "202604",
      totalExpenses: MonetaryAmount(cents: 15000, currency: .defaultCurrency)
    ),
  ]

  ExpenseBreakdownCard(breakdown: breakdown, categories: Categories(from: categories))
    .frame(width: 400)
    .padding()
}
