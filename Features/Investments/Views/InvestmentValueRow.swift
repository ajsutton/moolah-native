import SwiftUI

struct InvestmentValueRow: View {
  let value: InvestmentValue
  let onDelete: () -> Void

  var body: some View {
    HStack {
      Text(value.date, format: .dateTime.day().month().year())
        .font(.headline)
        .monospacedDigit()

      Spacer()

      MonetaryAmountView(amount: value.value, colorOverride: .primary)
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
