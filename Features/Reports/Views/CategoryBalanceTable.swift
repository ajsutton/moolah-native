import SwiftUI

/// Displays a table of category balances grouped by root category with expandable subcategories.
/// Used for both income and expense columns in the Reports view.
struct CategoryBalanceTable: View {
  let title: String
  let balances: [UUID: InstrumentAmount]
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
          totalAmount: .zero(instrument: amount.instrument),
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
        sorted.children.sort { $0.amount.quantity.magnitude > $1.amount.quantity.magnitude }
        return sorted
      }
      .sorted { $0.totalAmount.quantity.magnitude > $1.totalAmount.quantity.magnitude }
  }

  private var grandTotal: InstrumentAmount {
    balances.values.reduce(.zero(instrument: balances.values.first?.instrument ?? .AUD), +)
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
                      InstrumentAmountView(amount: child.amount)
                    }
                  }
                }
              }
            } header: {
              HStack {
                Text(group.name)
                  .font(.headline)
                Spacer()
                InstrumentAmountView(amount: group.totalAmount, font: .headline)
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
        InstrumentAmountView(amount: grandTotal, font: .headline)
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

}

struct CategoryGroup: Identifiable {
  let categoryId: UUID
  let name: String
  var totalAmount: InstrumentAmount
  var children: [CategoryChild]

  var id: UUID { categoryId }
}

struct CategoryChild: Identifiable {
  let categoryId: UUID
  let name: String
  let amount: InstrumentAmount

  var id: UUID { categoryId }
}

struct CategoryDrillDown: Hashable {
  let categoryId: UUID
  let dateRange: ClosedRange<Date>
}
