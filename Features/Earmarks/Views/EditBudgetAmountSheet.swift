import SwiftUI

struct EditBudgetAmountSheet: View {
  let earmark: Earmark
  let lineItem: BudgetLineItem
  @State private var amountText: String
  @Environment(EarmarkStore.self) private var earmarkStore
  @Environment(\.dismiss) private var dismiss

  init(earmark: Earmark, lineItem: BudgetLineItem) {
    self.earmark = earmark
    self.lineItem = lineItem
    _amountText = State(initialValue: lineItem.budgeted.formatNoSymbol)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Budget for \(lineItem.categoryName)") {
          HStack {
            Text(lineItem.budgeted.currency.symbol)
              .foregroundStyle(.secondary)
            TextField("Amount", text: $amountText)
              #if os(iOS)
                .keyboardType(.decimalPad)
              #endif
          }
        }
      }
      .formStyle(.grouped)
      .navigationTitle("Edit Budget")
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
          .disabled(amountText.isEmpty)
        }
      }
    }
    .presentationDetents([.medium])
  }

  private func save() {
    guard let cents = MonetaryAmount.parseCents(from: amountText) else { return }
    let amount = MonetaryAmount(cents: cents, currency: lineItem.budgeted.currency)
    Task {
      await earmarkStore.updateBudgetItem(
        earmarkId: earmark.id,
        categoryId: lineItem.id,
        amount: amount
      )
      dismiss()
    }
  }
}
