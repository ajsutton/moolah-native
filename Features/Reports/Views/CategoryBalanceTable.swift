import SwiftUI

/// Displays a table of category balances grouped by root category with expandable subcategories.
/// Used for both income and expense columns in the Reports view.
struct CategoryBalanceTable: View {
  let title: String
  let balances: [UUID: Int]
  let categories: Categories
  let dateRange: ClosedRange<Date>

  private var reportData: [CategoryGroup] {
    // Group subcategories under roots
    var roots: [UUID: CategoryGroup] = [:]

    for (categoryId, amount) in balances {
      guard categories.by(id: categoryId) != nil else { continue }

      // Find root category
      let rootId = rootCategoryId(for: categoryId)

      // Get or create root group
      var group =
        roots[rootId]
        ?? CategoryGroup(
          categoryId: rootId,
          name: categories.by(id: rootId)?.name ?? "Unknown",
          totalAmount: 0,
          children: []
        )

      // If this is the root itself, just add to total
      if categoryId == rootId {
        group.totalAmount += amount
      } else {
        // Add as child
        group.children.append(
          CategoryChild(
            categoryId: categoryId,
            name: categories.by(id: categoryId)?.name ?? "Unknown",
            amount: amount
          ))
        group.totalAmount += amount
      }

      roots[rootId] = group
    }

    // Sort roots by total (descending), then children by amount (descending)
    return roots.values
      .map { group in
        var sorted = group
        sorted.children.sort { $0.amount.magnitude > $1.amount.magnitude }
        return sorted
      }
      .sorted { $0.totalAmount.magnitude > $1.totalAmount.magnitude }
  }

  private var grandTotal: Int {
    balances.values.reduce(0, +)
  }

  var body: some View {
    VStack(spacing: 0) {
      // Header
      HStack {
        Text(title)
          .font(.title2)
          .fontWeight(.semibold)
        Spacer()
      }
      .padding()

      Divider()

      // Table
      if reportData.isEmpty {
        // Empty state
        ContentUnavailableView(
          "No Transactions",
          systemImage: "tray",
          description: Text("No transactions found for this period")
        )
      } else {
        List {
          ForEach(reportData) { group in
            Section {
              // Only show children if there are any
              if !group.children.isEmpty {
                ForEach(group.children) { child in
                  NavigationLink(
                    value: CategoryDrillDown(
                      categoryId: child.categoryId,
                      dateRange: dateRange
                    )
                  ) {
                    HStack {
                      Text(child.name)
                        .font(.body)
                      Spacer()
                      Text(formatCurrency(child.amount))
                        .monospacedDigit()
                    }
                  }
                }
              }
            } header: {
              HStack {
                Text(group.name)
                  .font(.headline)
                Spacer()
                Text(formatCurrency(group.totalAmount))
                  .font(.headline)
                  .monospacedDigit()
              }
            }
          }
        }
        .listStyle(.plain)
      }

      // Footer
      Divider()
      HStack {
        Text("Total")
          .font(.headline)
        Spacer()
        Text(formatCurrency(grandTotal))
          .font(.headline)
          .monospacedDigit()
      }
      .padding()
    }
  }

  private func rootCategoryId(for categoryId: UUID) -> UUID {
    var current = categoryId
    while let category = categories.by(id: current),
      let parentId = category.parentId
    {
      current = parentId
    }
    return current
  }

  private func formatCurrency(_ amount: Int) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = Currency.defaultCurrency.code
    return formatter.string(from: NSNumber(value: Double(amount) / 100)) ?? "$0.00"
  }
}

struct CategoryGroup: Identifiable {
  let categoryId: UUID
  let name: String
  var totalAmount: Int
  var children: [CategoryChild]

  var id: UUID { categoryId }
}

struct CategoryChild: Identifiable {
  let categoryId: UUID
  let name: String
  let amount: Int

  var id: UUID { categoryId }
}

struct CategoryDrillDown: Hashable {
  let categoryId: UUID
  let dateRange: ClosedRange<Date>
}
