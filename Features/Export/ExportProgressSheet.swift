import SwiftUI

/// Non-dismissable modal sheet shown while a profile export is running.
/// Observes `ProfileSession.activeExport` via the enclosing view's binding.
struct ExportProgressSheet: View {
  let profileLabel: String
  let stageLabel: String

  var body: some View {
    VStack(spacing: 18) {
      ProgressView()
        .progressViewStyle(.circular)
        .controlSize(.large)

      VStack(spacing: 4) {
        Text("Exporting \(profileLabel)")
          .font(.headline)
        Text(stageLabel)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      .multilineTextAlignment(.center)
    }
    .padding(24)
    #if os(macOS)
      .frame(minWidth: 420, minHeight: 280)
    #endif
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Exporting \(profileLabel). \(stageLabel)")
    .accessibilityAddTraits(.updatesFrequently)
  }
}

#if DEBUG
  #Preview("Fetching transactions") {
    ExportProgressSheet(
      profileLabel: "Moolah.rocks (iCloud)",
      stageLabel: "Fetching transactions…"
    )
  }

  #Preview("Writing file") {
    ExportProgressSheet(
      profileLabel: "Moolah.rocks (iCloud)",
      stageLabel: "Writing file…"
    )
  }
#endif
