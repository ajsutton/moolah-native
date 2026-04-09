import SwiftUI

struct AddBudgetLineItemSheet: View {
  let earmark: Earmark
  let categories: Categories
  let existingCategoryIds: Set<UUID>
  @State private var selectedCategoryId: UUID?
  @State private var amountText = ""
  @Environment(EarmarkStore.self) private var earmarkStore
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Form {
        Section("Category") {
          CategoryPicker(categories: categories, selection: $selectedCategoryId)
        }

        Section("Budget Amount") {
          HStack {
            Text(earmark.balance.currency.symbol)
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
    let amount = MonetaryAmount(cents: cents, currency: earmark.balance.currency)
    Task {
      await earmarkStore.addBudgetItem(
        earmarkId: earmark.id,
        categoryId: categoryId,
        amount: amount
      )
      dismiss()
    }
  }

}
