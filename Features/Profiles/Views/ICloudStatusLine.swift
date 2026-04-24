import SwiftUI

/// Quiet status line that sits under the hero CTA in state 1.
/// Shows a spinner + "Checking iCloud for your profiles…" while we're
/// waiting, swaps to "No profiles in iCloud yet." once a fetch has
/// completed empty. Never visible in state 4 (iCloud unavailable) —
/// that's handled by ``ICloudOffChip``.
struct ICloudStatusLine: View {
  enum State: Equatable {
    case checking
    case noneFound
  }

  let state: State

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      if state == .checking {
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
    .accessibilityAddTraits(state == .checking ? .updatesFrequently : [])
  }

  private var label: String {
    switch state {
    case .checking:
      String(localized: "Checking iCloud for your profiles…")
    case .noneFound:
      String(localized: "No profiles in iCloud yet.")
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
