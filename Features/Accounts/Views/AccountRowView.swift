import SwiftUI

/// Shared row view for sidebar items (accounts, earmarks) that displays
/// an icon, name, and balance with selection-aware color coding.
/// When `isSelected` is true, uses `.mint` / `.pink` instead of `.green` / `.red`
/// for better contrast against the blue selection highlight.
struct SidebarRowView: View {
  let icon: String
  let name: String
  let amount: InstrumentAmount?
  var isSelected: Bool = false

  @Environment(\.backgroundProminence) private var backgroundProminence

  /// Bright green/red that contrast well against the blue selection highlight.
  private static let selectedPositiveColor = Color(red: 0.55, green: 1.0, blue: 0.65)
  private static let selectedNegativeColor = Color(red: 1.0, green: 0.6, blue: 0.6)

  private var amountColorOverride: Color? {
    // Only use bright overrides when the row has a prominent (blue) selection
    // background. When the sidebar is unfocused the background is grey and
    // standard green/red are more readable.
    guard let amount, isSelected, backgroundProminence == .increased else { return nil }
    if amount.isPositive { return Self.selectedPositiveColor }
    if amount.isNegative { return Self.selectedNegativeColor }
    return nil
  }

  var body: some View {
    HStack {
      Image(systemName: icon)
        .foregroundStyle(.secondary)
        .frame(width: UIConstants.IconSize.listIcon, height: UIConstants.IconSize.listIcon)
        .accessibilityHidden(true)

      Text(name)

      Spacer()

      if let amount {
        InstrumentAmountView(amount: amount, colorOverride: amountColorOverride)
      } else {
        ProgressView()
          .controlSize(.small)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilitySummary)
  }

  private var accessibilitySummary: String {
    guard let amount else { return "\(name), balance loading" }
    return "\(name), \(amount.formatted)"
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

/// Sidebar row for an account. Asynchronously loads the full converted balance
/// (sum of all positions in the account's instrument) via `AccountStore.displayBalance`
/// and shows a spinner while it's in flight.
struct AccountSidebarRow: View {
  let account: Account
  var isSelected: Bool = false
  @Environment(AccountStore.self) private var accountStore
  @State private var balance: InstrumentAmount?

  var body: some View {
    SidebarRowView(
      icon: account.sidebarIcon,
      name: account.name,
      amount: balance,
      isSelected: isSelected
    )
    .task(id: balanceInputs) {
      balance = try? await accountStore.displayBalance(for: account.id)
    }
  }

  private var balanceInputs: BalanceInputs {
    BalanceInputs(
      positions: account.positions,
      investmentValue: accountStore.investmentValues[account.id]
    )
  }

  private struct BalanceInputs: Equatable {
    let positions: [Position]
    let investmentValue: InstrumentAmount?
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
