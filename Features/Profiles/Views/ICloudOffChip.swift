import SwiftUI

/// Inline chip shown under the hero CTA in state 4 (iCloud unavailable).
/// Explains that the profile will be local and links to System Settings.
///
/// `openSettingsAction` performs the platform-appropriate deep link —
/// wired by the host (`WelcomeView`, Task 13) so this view stays
/// platform-agnostic.
struct ICloudOffChip: View {
  let openSettingsAction: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: "icloud.slash")
        .foregroundStyle(WelcomeBrandColors.coralRed)
        .font(.footnote)
        .padding(.top, 2)
      VStack(alignment: .leading, spacing: 3) {
        Text("iCloud sync is off.", comment: "First-run iCloud-off chip title")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(WelcomeBrandColors.coralRed)
        HStack(spacing: 4) {
          Text(
            "Your profile will be saved on this device.",
            comment: "First-run iCloud-off chip body"
          )
          .font(.footnote)
          .foregroundStyle(WelcomeBrandColors.muted)
          Button(action: openSettingsAction) {
            Text("Open System Settings", comment: "First-run iCloud-off chip link")
              .font(.footnote)
              .underline()
              .foregroundStyle(WelcomeBrandColors.lightBlue)
              .frame(minHeight: 44)
          }
          .buttonStyle(.plain)
        }
      }
    }
    .padding(10)
    .background(WelcomeBrandColors.coralRed.opacity(0.12))
    .clipShape(.rect(cornerRadius: 8))
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "iCloud sync is off. Your profile will be saved on this device."
    )
    .accessibilityAction(named: "Open System Settings", openSettingsAction)
  }
}

#Preview("ICloudOffChip") {
  ZStack {
    WelcomeBrandColors.space.ignoresSafeArea()
    ICloudOffChip(openSettingsAction: {}).padding()
  }
  .frame(width: 360, height: 120)
}

#Preview("ICloudOffChip — dark") {
  ZStack {
    WelcomeBrandColors.space.ignoresSafeArea()
    ICloudOffChip(openSettingsAction: {}).padding()
  }
  .frame(width: 360, height: 120)
  .preferredColorScheme(.dark)
}

#Preview("ICloudOffChip — AX5") {
  ZStack {
    WelcomeBrandColors.space.ignoresSafeArea()
    ICloudOffChip(openSettingsAction: {}).padding()
  }
  .frame(width: 500, height: 240)
  .dynamicTypeSize(.accessibility5)
}
