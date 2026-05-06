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
  /// When non-nil, the row replaces the amount with this short label
  /// (e.g. "Not set") and the accompanying VoiceOver phrase. Used by
  /// `AccountSidebarRow` for recorded-value investment accounts that have
  /// no recorded snapshot, so the sidebar doesn't roll a synthetic `$0` into
  /// the user's mental model of the column. See guides/UI_GUIDE.md §"Not set"
  /// and `INSTRUMENT_CONVERSION_GUIDE.md` Rule 11 for the rationale.
  var unsetIndicator: String?

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

      trailingValue
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilitySummary)
  }

  @ViewBuilder private var trailingValue: some View {
    if let unsetIndicator {
      Text(unsetIndicator)
        .font(.caption)
        .foregroundStyle(.secondary)
    } else if let amount {
      InstrumentAmountView(amount: amount, colorOverride: amountColorOverride)
    } else {
      ProgressView()
        .controlSize(.small)
    }
  }

  private var accessibilitySummary: String {
    if let unsetIndicator { return "\(name), \(unsetIndicator)" }
    guard let amount else { return "\(name), balance loading" }
    return "\(name), \(amount.formatted)"
  }
}

/// Sidebar row for an account. Reads the converted balance from
/// `AccountStore.convertedBalances` (populated and retried by the store
/// when conversions fail). Shows a spinner while no balance is available.
///
/// Recorded-value investment accounts with no externally-set value render
/// "Not set" instead of `$0` once the initial conversion pass has completed
/// — `$0` would be indistinguishable from "user entered zero" and would
/// roll into net-worth as a real number rather than a missing one. See
/// `INSTRUMENT_CONVERSION_GUIDE.md` Rule 11 and the design note in
/// `plans/per-account-valuation-mode.md`.
struct AccountSidebarRow: View {
  let account: Account
  var isSelected: Bool = false
  @Environment(AccountStore.self) private var accountStore

  var body: some View {
    SidebarRowView(
      icon: account.sidebarIcon,
      name: account.name,
      amount: accountStore.convertedBalances[account.id],
      isSelected: isSelected,
      unsetIndicator: accountStore.hasUnrecordedValue(account) ? "Not set" : nil
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

#Preview("Sidebar row — Not set indicator") {
  List(selection: .constant(Optional("loaded"))) {
    SidebarRowView(
      icon: "chart.line.uptrend.xyaxis",
      name: "Brokerage (no value)",
      amount: InstrumentAmount(quantity: 0, instrument: .AUD),
      unsetIndicator: "Not set"
    )
    .tag("loaded")

    SidebarRowView(
      icon: "chart.line.uptrend.xyaxis",
      name: "Brokerage (loading)",
      amount: nil
    )
    .tag("loading")
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
