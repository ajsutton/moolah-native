import SwiftUI

/// Non-blocking brand-gold banner surfaced above the create-profile
/// form (state 3) when iCloud returns profiles while the user is
/// mid-setup.
///
/// Single-profile path → Open/Dismiss. Multi-profile path → View/Dismiss.
///
/// Brand colour is deliberately kept (not system yellow) — this is the
/// one system-styled screen element that sits narratively with the
/// hero (iCloud has something for you). See design spec §4.1.
struct ICloudArrivalBanner: View {
  enum Kind: Equatable {
    case single(label: String)
    case multiple(count: Int)
  }

  let kind: Kind
  let primaryAction: () -> Void
  let dismissAction: () -> Void

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Image(systemName: "icloud")
        .foregroundStyle(WelcomeBrandColors.space)
        .padding(.top, 1)
      labels
      Spacer(minLength: 0)
      actions
    }
    .padding(12)
    .background(WelcomeBrandColors.balanceGold.opacity(0.95))
    .clipShape(.rect(cornerRadius: 10))
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityLabelText)
    .accessibilityAction(named: primaryLabel, primaryAction)
    .accessibilityAction(named: "Dismiss", dismissAction)
    .accessibilityAddTraits(.updatesFrequently)
  }

  private var labels: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(.footnote.weight(.semibold))
        .foregroundStyle(WelcomeBrandColors.space)
      if let subtitle {
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(WelcomeBrandColors.space.opacity(0.75))
      }
    }
  }

  private var actions: some View {
    HStack(spacing: 12) {
      Button(primaryLabel, action: primaryAction)
        .buttonStyle(.plain)
        .font(.footnote.weight(.semibold))
        .foregroundStyle(WelcomeBrandColors.space)
        .underline()
        .frame(minHeight: 44)
      Button(action: dismissAction) {
        Text("Dismiss", comment: "First-run iCloud banner dismiss")
          .font(.footnote)
          .foregroundStyle(WelcomeBrandColors.space.opacity(0.6))
          .frame(minHeight: 44)
      }
      .buttonStyle(.plain)
    }
  }

  private var title: String {
    switch kind {
    case .single(let label):
      return String(localized: "Found '\(label)' in iCloud.")
    case .multiple(let count):
      return String(localized: "Looks like you've got \(count) profiles in iCloud.")
    }
  }

  private var subtitle: String? {
    switch kind {
    case .single:
      return String(localized: "You can open it instead of creating a new one.")
    case .multiple:
      return nil
    }
  }

  private var primaryLabel: String {
    switch kind {
    case .single:
      return String(localized: "Open")
    case .multiple:
      return String(localized: "View")
    }
  }

  private var accessibilityLabelText: String {
    if let subtitle {
      return "\(title). \(subtitle)"
    }
    return title
  }
}

#Preview("Single") {
  ICloudArrivalBanner(
    kind: .single(label: "Household"),
    primaryAction: {},
    dismissAction: {}
  )
  .padding()
  .frame(width: 440, height: 120)
}

#Preview("Multiple") {
  ICloudArrivalBanner(
    kind: .multiple(count: 3),
    primaryAction: {},
    dismissAction: {}
  )
  .padding()
  .frame(width: 440, height: 120)
}

#Preview("Single — dark") {
  ICloudArrivalBanner(
    kind: .single(label: "Household"),
    primaryAction: {},
    dismissAction: {}
  )
  .padding()
  .frame(width: 440, height: 120)
  .preferredColorScheme(.dark)
}

#Preview("Multiple — AX5") {
  ICloudArrivalBanner(
    kind: .multiple(count: 3),
    primaryAction: {},
    dismissAction: {}
  )
  .padding()
  .frame(width: 560, height: 240)
  .dynamicTypeSize(.accessibility5)
}
