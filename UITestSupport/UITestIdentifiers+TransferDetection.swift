import Foundation

extension UITestIdentifiers {
  // MARK: - TransferDetection

  // `merge(_:)` / `dismiss(_:)` are shared by the Recently Added row
  // actions and the transaction-detail suggestion section. The two
  // surfaces never co-exist on macOS — the detail is an inspector that
  // replaces the row in place, never a sheet presented over the Recently
  // Added list — and UI tests are macOS-only (`MoolahUITests_macOS`), so
  // resolving `merge(txId)` / `dismiss(txId)` to a single element is
  // unambiguous and the constants are reused rather than duplicated.
  public enum TransferDetection {
    /// Passive "possible transfer" pill on a Recently Added row. `id` is
    /// the annotated transaction's UUID, lowercased.
    public static func pill(_ id: UUID) -> String {
      "transferdetection.pill.\(id.uuidString.lowercased())"
    }

    /// "Merge as Transfer" action for the transaction with the given
    /// UUID, lowercased. Shared by the Recently Added row (context menu /
    /// iOS swipe) and the transaction-detail suggestion section's button.
    public static func merge(_ id: UUID) -> String {
      "transferdetection.merge.\(id.uuidString.lowercased())"
    }

    /// "Not a Transfer" dismissal action for the transaction with the
    /// given UUID, lowercased. Shared by the Recently Added row (context
    /// menu / iOS swipe) and the transaction-detail suggestion section's
    /// button.
    public static func dismiss(_ id: UUID) -> String {
      "transferdetection.dismiss.\(id.uuidString.lowercased())"
    }

    /// Sentinel for the transaction-detail transfer-suggestion banner
    /// section. `id` is the annotated transaction's UUID, lowercased.
    /// Lets a macOS UI test assert the banner is present (or absent
    /// after a merge / dismiss) without depending on the banner copy.
    public static func detailBanner(_ id: UUID) -> String {
      "transferdetection.detail.banner.\(id.uuidString.lowercased())"
    }
  }
}
