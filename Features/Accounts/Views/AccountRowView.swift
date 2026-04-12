import SwiftUI

/// Shared row view for sidebar items (accounts, earmarks) that displays
/// an icon, name, and balance with selection-aware color coding.
/// When `isSelected` is true, uses `.mint` / `.pink` instead of `.green` / `.red`
/// for better contrast against the blue selection highlight.
struct SidebarRowView: View {
  let icon: String
  let name: String
  let amount: InstrumentAmount
  var isSelected: Bool = false

  @Environment(\.backgroundProminence) private var backgroundProminence

  /// Bright green/red that contrast well against the blue selection highlight.
  private static let selectedPositiveColor = Color(red: 0.55, green: 1.0, blue: 0.65)
  private static let selectedNegativeColor = Color(red: 1.0, green: 0.6, blue: 0.6)

  private var amountColorOverride: Color? {
    // Only use bright overrides when the row has a prominent (blue) selection
    // background. When the sidebar is unfocused the background is grey and
    // standard green/red are more readable.
    guard isSelected, backgroundProminence == .increased else { return nil }
    if amount.isPositive { return Self.selectedPositiveColor }
    if amount.isNegative { return Self.selectedNegativeColor }
    return nil
  }

  var body: some View {
    HStack {
      Image(systemName: icon)
        .foregroundStyle(.secondary)
        .frame(width: UIConstants.IconSize.listIcon, height: UIConstants.IconSize.listIcon)

      Text(name)

      Spacer()

      MonetaryAmountView(amount: amount, colorOverride: amountColorOverride)
    }
  }
}

extension Account {
  var sidebarIcon: String {
    switch type {
    case .bank: return "building.columns"
    case .asset: return "house.fill"
    case .creditCard: return "creditcard"
    case .investment: return "chart.line.uptrend.xyaxis"
    }
  }
}

#Preview {
  List(selection: .constant(Optional("selected"))) {
    SidebarRowView(
      icon: "building.columns",
      name: "Bank Account (selected)",
      amount: InstrumentAmount(quantity: 1234.56, instrument: .AUD),
      isSelected: true
    )
    .tag("selected")

    SidebarRowView(
      icon: "bookmark.fill",
      name: "Holiday Fund",
      amount: InstrumentAmount(quantity: 1500.00, instrument: .AUD)
    )
    .tag("other1")

    SidebarRowView(
      icon: "creditcard",
      name: "Credit Card",
      amount: InstrumentAmount(quantity: -500.00, instrument: .AUD)
    )
    .tag("other2")
  }
  .listStyle(.sidebar)
}
