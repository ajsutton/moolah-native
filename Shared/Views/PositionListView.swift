import SwiftUI

/// Displays a list of instrument positions for an account.
/// Only shown when the account holds more than one instrument.
struct PositionListView: View {
  let positions: [Position]

  var body: some View {
    if positions.count > 1 {
      Section("Balances") {
        ForEach(positions, id: \.instrument) { position in
          HStack {
            Text(position.instrument.name)
            Spacer()
            Text(position.amount.formatted)
              .monospacedDigit()
              .foregroundStyle(positionColor(position))
          }
          .accessibilityLabel(
            "\(position.instrument.name): \(position.amount.formatted)"
          )
        }
      }
    }
  }

  private func positionColor(_ position: Position) -> Color {
    if position.quantity > 0 { return .green }
    if position.quantity < 0 { return .red }
    return .primary
  }
}
