import SwiftUI

struct CreateEarmarkSheet: View {
  let currency: Currency
  let onCreate: (Earmark) -> Void

  @State private var name: String = ""
  @State private var savingsGoal: String = ""
  @State private var startDate: Date = Date()
  @State private var endDate: Date = Calendar.current.date(byAdding: .year, value: 1, to: Date())!
  @State private var useDateRange: Bool = false
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Form {
        Section("Details") {
          TextField("Name", text: $name)
        }

        Section("Savings Goal") {
          HStack {
            Text(currency.code)
              .foregroundStyle(.secondary)
            TextField("Amount", text: $savingsGoal)
              #if os(iOS)
                .keyboardType(.decimalPad)
              #endif
          }

          Toggle("Set Date Range", isOn: $useDateRange)

          if useDateRange {
            DatePicker("Start Date", selection: $startDate, displayedComponents: .date)
            DatePicker("End Date", selection: $endDate, displayedComponents: .date)
          }
        }
      }
      .formStyle(.grouped)
      .navigationTitle("New Earmark")
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
          Button("Create") {
            createEarmark()
          }
          .disabled(name.isEmpty)
        }
      }
    }
  }

  private func createEarmark() {
    let goalCents = MonetaryAmount.parseCents(from: savingsGoal)
    let goal =
      goalCents.flatMap { $0 > 0 ? MonetaryAmount(cents: $0, currency: currency) : nil }

    let newEarmark = Earmark(
      name: name,
      savingsGoal: goal,
      savingsStartDate: useDateRange ? startDate : nil,
      savingsEndDate: useDateRange ? endDate : nil
    )
    onCreate(newEarmark)
  }
}

struct EditEarmarkSheet: View {
  let earmark: Earmark
  let onUpdate: (Earmark) -> Void

  @State private var name: String
  @State private var savingsGoal: String
  @State private var startDate: Date
  @State private var endDate: Date
  @State private var useDateRange: Bool
  @State private var isHidden: Bool
  @Environment(\.dismiss) private var dismiss

  init(earmark: Earmark, onUpdate: @escaping (Earmark) -> Void) {
    self.earmark = earmark
    self.onUpdate = onUpdate
    _name = State(initialValue: earmark.name)
    _savingsGoal = State(initialValue: earmark.savingsGoal?.decimalValue.description ?? "")
    _startDate = State(initialValue: earmark.savingsStartDate ?? Date())
    _endDate = State(
      initialValue: earmark.savingsEndDate ?? Calendar.current.date(
        byAdding: .year, value: 1, to: Date())!)
    _useDateRange = State(
      initialValue: earmark.savingsStartDate != nil || earmark.savingsEndDate != nil)
    _isHidden = State(initialValue: earmark.isHidden)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Details") {
          TextField("Name", text: $name)
          Toggle("Hidden", isOn: $isHidden)
        }

        Section("Savings Goal") {
          HStack {
            Text(earmark.balance.currency.code)
              .foregroundStyle(.secondary)
            TextField("Amount", text: $savingsGoal)
              #if os(iOS)
                .keyboardType(.decimalPad)
              #endif
          }

          Toggle("Set Date Range", isOn: $useDateRange)

          if useDateRange {
            DatePicker("Start Date", selection: $startDate, displayedComponents: .date)
            DatePicker("End Date", selection: $endDate, displayedComponents: .date)
          }
        }

        Section("Current Values") {
          LabeledContent("Balance") {
            MonetaryAmountView(amount: earmark.balance)
          }
          LabeledContent("Saved") {
            MonetaryAmountView(amount: earmark.saved)
          }
          LabeledContent("Spent") {
            MonetaryAmountView(amount: earmark.spent)
          }
        }
      }
      .formStyle(.grouped)
      .navigationTitle("Edit Earmark")
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
            saveChanges()
          }
          .disabled(name.isEmpty)
        }
      }
    }
  }

  private func saveChanges() {
    let goalCents = MonetaryAmount.parseCents(from: savingsGoal)
    let goal =
      goalCents.flatMap {
        $0 > 0 ? MonetaryAmount(cents: $0, currency: earmark.balance.currency) : nil
      }

    var updated = earmark
    updated.name = name
    updated.savingsGoal = goal
    updated.savingsStartDate = useDateRange ? startDate : nil
    updated.savingsEndDate = useDateRange ? endDate : nil
    updated.isHidden = isHidden

    onUpdate(updated)
  }
}
