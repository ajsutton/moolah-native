import SwiftUI

struct InvestmentValueRow: View {
  let value: InvestmentValue
  let onDelete: () -> Void

  var body: some View {
    HStack {
      Text(value.date, format: .dateTime.day().month(.abbreviated).year())
        .font(.headline)
        .monospacedDigit()

      Spacer()

      InstrumentAmountView(amount: value.value)
        .font(.headline)
    }
    .accessibilityElement(children: .combine)
    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
      Button(role: .destructive) {
        onDelete()
      } label: {
        Label("Delete", systemImage: "trash")
      }
    }
    .contextMenu {
      Button(role: .destructive) {
        onDelete()
      } label: {
        Label("Delete", systemImage: "trash")
      }
    }
  }
}
