import SwiftUI

/// Photos-style sync indicator for the sidebar footer.
///
/// Reads `SyncCoordinator.progress` and renders a two-line row on macOS
/// (icon + status + relative timestamp / counts) or a one-line compact
/// row on iOS. The row stays visible at all times on macOS so users know
/// the indicator exists; on iOS it only appears when the sidebar drawer
/// is open.
///
/// The label mapping lives on a nested `ViewModel` so it can be unit-tested
/// without SwiftUI.
struct SyncProgressFooter: View {
  @Environment(SyncCoordinator.self) private var syncCoordinator

  var body: some View {
    let viewModel = ViewModel(
      phase: syncCoordinator.progress.phase,
      recordsReceivedThisSession: syncCoordinator.progress.recordsReceivedThisSession,
      pendingUploads: syncCoordinator.progress.pendingUploads,
      lastSettledAt: syncCoordinator.progress.lastSettledAt
    )

    #if os(macOS)
      macOSRow(viewModel: viewModel)
    #else
      iOSRow(viewModel: viewModel)
    #endif
  }

  // MARK: - macOS

  #if os(macOS)
    @ViewBuilder
    private func macOSRow(viewModel: ViewModel) -> some View {
      HStack(alignment: .center, spacing: 10) {
        Image(systemName: viewModel.iconName)
          .foregroundStyle(viewModel.iconTint)
          .frame(width: 20)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(viewModel.title)
            .font(.subheadline)
            .accessibilityIdentifier(UITestIdentifiers.SyncFooter.label)
          if let detail = viewModel.detail {
            Text(detail)
              .font(.caption)
              .foregroundStyle(.secondary)
              .monospacedDigit()
              .accessibilityIdentifier(UITestIdentifiers.SyncFooter.detail)
          } else if let lastSettledAt = viewModel.lastSettledAt {
            TimelineView(.periodic(from: .now, by: 60)) { context in
              Text(
                "Updated \(lastSettledAt, format: .relative(presentation: .named, unitsStyle: .wide))",
                comment: "Relative time since last successful sync (sidebar footer)"
              )
              .font(.caption)
              .foregroundStyle(.secondary)
              .accessibilityIdentifier(UITestIdentifiers.SyncFooter.detail)
              .id(context.date)
            }
          }
        }
        Spacer()
          .accessibilityHidden(true)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(.regularMaterial)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier(UITestIdentifiers.SyncFooter.container)
    }
  #endif

  // MARK: - iOS

  #if os(iOS)
    @ViewBuilder
    private func iOSRow(viewModel: ViewModel) -> some View {
      HStack(spacing: 8) {
        Image(systemName: viewModel.iconName)
          .foregroundStyle(viewModel.iconTint)
        Text(viewModel.iOSLabel)
          .font(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()
          .accessibilityIdentifier(UITestIdentifiers.SyncFooter.label)
        Spacer()
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 6)
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier(UITestIdentifiers.SyncFooter.container)
    }
  #endif

  // MARK: - View model

  struct ViewModel {
    let phase: SyncProgress.Phase
    let recordsReceivedThisSession: Int
    let pendingUploads: Int
    let lastSettledAt: Date?

    private static let countFormatter: NumberFormatter = {
      let formatter = NumberFormatter()
      formatter.numberStyle = .decimal
      return formatter
    }()

    private static func formatted(_ value: Int) -> String {
      Self.countFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    var title: String {
      switch phase {
      case .idle, .connecting: return "Connecting\u{2026}"
      case .upToDate: return "Up to date"
      case .receiving: return "Receiving from iCloud"
      case .sending: return "Sending to iCloud"
      case .syncing: return "Syncing with iCloud"
      case .degraded(.quotaExceeded): return "iCloud storage full"
      case .degraded(.iCloudUnavailable): return "iCloud unavailable"
      case .degraded(.retrying): return "Retrying"
      }
    }

    var detail: String? {
      switch phase {
      case .receiving:
        return "\(Self.formatted(recordsReceivedThisSession)) records"
      case .sending:
        return "\(Self.formatted(pendingUploads)) changes"
      case .syncing:
        return
          "\(Self.formatted(recordsReceivedThisSession)) received \u{00B7} \(Self.formatted(pendingUploads)) to send"
      case .upToDate, .idle, .connecting, .degraded:
        return nil
      }
    }

    var iconName: String {
      switch phase {
      case .idle, .connecting: return "icloud"
      case .upToDate: return "checkmark.icloud"
      case .receiving: return "icloud.and.arrow.down"
      case .sending: return "icloud.and.arrow.up"
      case .syncing: return "arrow.up.arrow.down.circle"
      case .degraded(.quotaExceeded): return "exclamationmark.icloud"
      case .degraded(.iCloudUnavailable): return "xmark.icloud"
      case .degraded(.retrying): return "arrow.clockwise.icloud"
      }
    }

    var iconTint: Color {
      switch phase {
      case .degraded: return .orange
      default: return .secondary
      }
    }

    /// One-line compact label used on iOS (no relative timestamp line).
    var iOSLabel: String {
      if let detail { return "\(title) \u{00B7} \(detail)" }
      return title
    }
  }
}
