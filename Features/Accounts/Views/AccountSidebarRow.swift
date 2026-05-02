import SwiftUI

/// Shared row view for sidebar items (accounts, earmarks) that displays
/// an icon, name, and balance with selection-aware color coding.
/// When `isSelected` is true and the selection background is prominent
/// (focused sidebar), uses hand-tuned bright greens/reds instead of
/// `.green` / `.red` so the amount stays legible against the saturated
/// blue selection highlight. System colours `.mint` / `.pink` were tried
/// and rejected — too desaturated. See
/// guides/UI_GUIDE.md §5 "Selected-Row Contrast Override (Exception)"
/// for the rationale and the rule that this is the only place in the
/// app where hardcoded RGB values are permitted.
struct SidebarRowView: View {
  let icon: String
  let name: String
  let amount: InstrumentAmount?
  var isSelected: Bool = false

  @Environment(\.backgroundProminence) private var backgroundProminence

  /// Hand-tuned bright greens/reds that contrast well against the blue
  /// selection highlight. Documented exception to the "system colours
  /// only" rule in guides/UI_GUIDE.md §5.
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

/// Sidebar row for an account. Reads the converted balance from
/// `AccountStore.convertedBalances` (populated and retried by the store
/// when conversions fail). Shows a spinner while no balance is available.
struct AccountSidebarRow: View {
  let account: Account
  var isSelected: Bool = false
  @Environment(AccountStore.self) private var accountStore

  var body: some View {
    SidebarRowView(
      icon: account.sidebarIcon,
      name: account.name,
      amount: accountStore.convertedBalances[account.id],
      isSelected: isSelected
    )
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

#Preview("Sidebar row — negative balance selected") {
  List(selection: .constant(Optional("selected"))) {
    SidebarRowView(
      icon: "creditcard",
      name: "Credit Card (selected)",
      amount: InstrumentAmount(quantity: -500.00, instrument: .AUD),
      isSelected: true
    )
    .tag("selected")
  }
  .listStyle(.sidebar)
}

#Preview("Sidebar row — selected, dark mode") {
  List(selection: .constant(Optional("selected"))) {
    SidebarRowView(
      icon: "building.columns",
      name: "Bank Account (selected)",
      amount: InstrumentAmount(quantity: 1234.56, instrument: .AUD),
      isSelected: true
    )
    .tag("selected")

    SidebarRowView(
      icon: "creditcard",
      name: "Credit Card",
      amount: InstrumentAmount(quantity: -500.00, instrument: .AUD),
      isSelected: true
    )
    .tag("other")
  }
  .listStyle(.sidebar)
  .preferredColorScheme(.dark)
}
