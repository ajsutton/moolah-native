import SwiftUI

struct AddBudgetLineItemSheet: View {
  let earmark: Earmark
  let categories: Categories
  let existingCategoryIds: Set<UUID>
  @State private var selectedCategoryId: UUID?
  @State private var amountText = ""
  @Environment(EarmarkStore.self) private var earmarkStore
  @Environment(\.dismiss) private var dismiss

  private var availableCategories: [Category] {
    allCategories(from: categories)
      .filter { !existingCategoryIds.contains($0.id) }
      .sorted { $0.name < $1.name }
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Category") {
          Picker("Category", selection: $selectedCategoryId) {
            Text("Select a category").tag(UUID?.none)
            ForEach(availableCategories) { category in
              Text(category.name).tag(UUID?.some(category.id))
            }
          }
        }

        Section("Budget Amount") {
          HStack {
            Text(Currency.defaultCurrency.symbol)
              .foregroundStyle(.secondary)
            TextField("Amount", text: $amountText)
              #if os(iOS)
                .keyboardType(.decimalPad)
              #endif
          }
        }
      }
      .formStyle(.grouped)
      .navigationTitle("Add Budget Item")
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
            save()
          }
          .disabled(selectedCategoryId == nil || amountText.isEmpty)
        }
      }
    }
    .presentationDetents([.medium])
  }

  private func save() {
    guard let categoryId = selectedCategoryId else { return }
    let cents = MonetaryAmount.parseCents(from: amountText)
    let amount = MonetaryAmount(cents: cents, currency: Currency.defaultCurrency)
    Task {
      await earmarkStore.addBudgetItem(
        earmarkId: earmark.id,
        categoryId: categoryId,
        amount: amount
      )
      dismiss()
    }
  }

  /// Flattens the category hierarchy into a single list.
  private func allCategories(from categories: Categories) -> [Category] {
    var result: [Category] = []
    for root in categories.roots {
      result.append(root)
      result.append(contentsOf: categories.children(of: root.id))
    }
    return result
  }
}
