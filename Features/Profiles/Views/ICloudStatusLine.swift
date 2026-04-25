import SwiftUI

/// Quiet status line that sits under the hero CTA in state 1.
/// Shows a spinner + "Checking iCloud for your profiles…" while we're
/// waiting, swaps to "No profiles in iCloud yet." once a fetch has
/// completed empty. Never visible in state 4 (iCloud unavailable) —
/// that's handled by ``ICloudOffChip``.
struct ICloudStatusLine: View {
  enum State: Equatable {
    case checking
    case checkingActive(received: Int)
    case noneFound
  }

  let state: State

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      if isActivelyChecking {
        ProgressView()
          .controlSize(.small)
          .tint(WelcomeBrandColors.lightBlue)
      }
      Text(label)
        .font(.footnote)
        .foregroundStyle(WelcomeBrandColors.muted)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(label)
    .accessibilityAddTraits(accessibilityTraits)
    .accessibilityIdentifier(downloadingStatusIdentifier)
  }

  private var downloadingStatusIdentifier: String {
    switch state {
    case .checkingActive:
      return UITestIdentifiers.Welcome.heroDownloadingStatus
    default:
      return ""
    }
  }

  private var isActivelyChecking: Bool {
    switch state {
    case .checking, .checkingActive: return true
    case .noneFound: return false
    }
  }

  private var accessibilityTraits: AccessibilityTraits {
    switch state {
    case .checking, .checkingActive: return [.updatesFrequently]
    case .noneFound: return []
    }
  }

  private static let receivedCountFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    return formatter
  }()

  private var label: String {
    switch state {
    case .checking:
      return String(localized: "Checking iCloud for your profiles…")
    case .checkingActive(let received):
      let receivedString =
        Self.receivedCountFormatter.string(from: NSNumber(value: received))
        ?? "\(received)"
      return String(
        localized: "Found data on iCloud · \(receivedString) records downloaded")
    case .noneFound:
      return String(localized: "No profiles in iCloud yet.")
    }
  }
}

#Preview("Checking") {
  ZStack {
    WelcomeBrandColors.space.ignoresSafeArea()
    ICloudStatusLine(state: .checking).padding()
  }
  .frame(width: 360, height: 100)
}

#Preview("None found") {
  ZStack {
    WelcomeBrandColors.space.ignoresSafeArea()
    ICloudStatusLine(state: .noneFound).padding()
  }
  .frame(width: 360, height: 100)
}

#Preview("None found — dark") {
  ZStack {
    WelcomeBrandColors.space.ignoresSafeArea()
    ICloudStatusLine(state: .noneFound).padding()
  }
  .frame(width: 360, height: 100)
  .preferredColorScheme(.dark)
}

#Preview("Checking — AX5") {
  ZStack {
    WelcomeBrandColors.space.ignoresSafeArea()
    ICloudStatusLine(state: .checking).padding()
  }
  .frame(width: 520, height: 180)
  .dynamicTypeSize(.accessibility5)
}

#Preview("Downloading") {
  ZStack {
    WelcomeBrandColors.space.ignoresSafeArea()
    ICloudStatusLine(state: .checkingActive(received: 1234)).padding()
  }
  .frame(width: 360, height: 100)
}
