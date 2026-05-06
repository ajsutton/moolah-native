import SwiftUI

/// Stop-the-world view shown when a profile's `dataFormatVersion`
/// exceeds `DataFormatVersion.current` (issue #764).
///
/// Pure function of its inputs — no async, no error states, no
/// spinners. The routing layer wires the closures.
struct IncompatibleProfileView: View {
  let info: IncompatibleProfileInfo
  let onCheckForUpdates: () -> Void
  let onSwitchProfile: () -> Void

  var body: some View {
    VStack(spacing: 24) {
      Image(systemName: "arrow.up.circle.fill")
        .font(.system(size: 56))
        .foregroundStyle(.tint)
        .accessibilityHidden(true)

      Text("Update Moolah to Continue")
        .font(.title)
        .accessibilityAddTraits(.isHeader)

      Text(bodyText)
        .multilineTextAlignment(.center)
        .foregroundStyle(.secondary)
        .frame(maxWidth: 420)

      HStack(spacing: 12) {
        Button("Switch Profile", action: onSwitchProfile)
          .buttonStyle(.bordered)
          .accessibilityIdentifier("incompatibleProfile.switchProfile")

        Button("Check for Updates", action: onCheckForUpdates)
          .buttonStyle(.borderedProminent)
          .accessibilityIdentifier("incompatibleProfile.checkForUpdates")
      }
      .controlSize(.large)

      Text(versionDetail)
        .font(.footnote)
        .monospacedDigit()
        .foregroundStyle(.tertiary)
        .accessibilityLabel(
          "Profile format version \(info.profileVersion). This build supports version \(info.buildVersion)."
        )
    }
    .padding(40)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityIdentifier("incompatibleProfile.root")
  }

  private var bodyText: String {
    "\u{201C}\(info.profileLabel)\u{201D} was last used by a newer version of Moolah. Update the app to open this profile, or switch to another profile."
  }

  private var versionDetail: String {
    "Profile format v\(info.profileVersion) · This build supports v\(info.buildVersion) (\(AppVersion.shortVersionString))"
  }
}

#Preview("Incompatible Profile") {
  IncompatibleProfileView(
    info: IncompatibleProfileInfo(
      profileLabel: "Personal Finance",
      profileVersion: 5,
      buildVersion: 4
    ),
    onCheckForUpdates: {},
    onSwitchProfile: {}
  )
}

#Preview("Long label") {
  IncompatibleProfileView(
    info: IncompatibleProfileInfo(
      profileLabel: "My Very Long Profile Name That Might Wrap",
      profileVersion: 12,
      buildVersion: 4
    ),
    onCheckForUpdates: {},
    onSwitchProfile: {}
  )
}
