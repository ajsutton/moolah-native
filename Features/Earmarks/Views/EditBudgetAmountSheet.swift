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
      form
    }
    .presentationDetents([.medium])
    #if os(macOS)
      .frame(minWidth: 400, minHeight: 300)
    #endif
  }

  private var form: some View {
    Form {
      Section("Budget for \(lineItem.categoryPath)") {
        HStack {
          Text(lineItem.budgeted.instrument.currencySymbol ?? lineItem.budgeted.instrument.id)
            .foregroundStyle(.secondary)
          TextField("Amount", text: $amountText)
            .monospacedDigit()
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
        Button("Cancel") { dismiss() }
      }
      ToolbarItem(placement: .confirmationAction) {
        Button("Save") { save() }
          .disabled(amountText.isEmpty)
      }
    }
  }

  private func save() {
    guard
      let qty = InstrumentAmount.parseQuantity(
        from: amountText, decimals: lineItem.budgeted.instrument.decimals)
    else { return }
    let amount = InstrumentAmount(quantity: qty, instrument: lineItem.budgeted.instrument)
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
