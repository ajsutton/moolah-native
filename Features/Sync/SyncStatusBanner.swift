import SwiftUI

/// Non-modal banner displayed when iCloud storage is full.
/// Appears at the top of the content area and persists until
/// the condition clears or the user dismisses it.
struct SyncStatusBanner: View {
  @Environment(SyncCoordinator.self) private var syncCoordinator
  @State private var dismissed = false

  var body: some View {
    if syncCoordinator.isQuotaExceeded && !dismissed {
      HStack {
        Image(systemName: "exclamationmark.icloud.fill")
          .foregroundStyle(.orange)
        Text("iCloud storage is full. Some changes can't sync until you free up space.")
          .font(.callout)
        Spacer()
        Button {
          dismissed = true
        } label: {
          Image(systemName: "xmark")
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dismiss sync warning")
      }
      .padding(.horizontal)
      .padding(.vertical, 8)
      .background(.yellow.opacity(0.15))
      .onChange(of: syncCoordinator.isQuotaExceeded) { old, new in
        // Reset dismissal when the condition clears and reappears
        if !old && new {
          dismissed = false
        }
      }
    }
  }
}
