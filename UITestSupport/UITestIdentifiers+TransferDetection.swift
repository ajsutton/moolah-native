import Foundation

extension UITestIdentifiers {
  // MARK: - TransferDetection

  // `merge(_:)` / `dismiss(_:)` / `unmerge(_:)` are shared by the
  // Recently Added row actions and the transaction-detail section. The
  // two surfaces never co-exist on macOS — the detail is an inspector
  // that replaces the row in place, never a sheet presented over the
  // Recently Added list — and UI tests are macOS-only
  // (`MoolahUITests_macOS`), so resolving `merge(txId)` /
  // `dismiss(txId)` / `unmerge(txId)` to a single element is unambiguous
  // and the constants are reused rather than duplicated.
  public enum TransferDetection {
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

    /// "Split Back into Separate Transactions" unmerge action for the
    /// transaction with the given UUID, lowercased. Shared by the
    /// Recently Added row context menu and the transaction-detail
    /// unmerge section's button.
    public static func unmerge(_ id: UUID) -> String {
      "transferdetection.unmerge.\(id.uuidString.lowercased())"
    }

    /// Sentinel for the transaction-detail transfer-suggestion banner
    /// section. `id` is the annotated transaction's UUID, lowercased.
    /// Lets a macOS UI test assert the banner is present (or absent
    /// after a merge / dismiss) without depending on the banner copy.
    public static func detailBanner(_ id: UUID) -> String {
      "transferdetection.detail.banner.\(id.uuidString.lowercased())"
    }

    /// Destructive confirm button of the "Dismiss Transfer Suggestion"
    /// confirmation dialog. Resolved by identifier rather than the
    /// English title so the dismiss driver does not couple to copy and
    /// does not collide with the look-alike delete-confirmation button.
    public static let dismissConfirm = "transferdetection.dismiss.confirm"

    /// Leading text of the passive "possible transfer" pill title
    /// (`"Possible transfer"` / `"Possible transfer to <Account>"`).
    /// The Recently Added row wraps its content in
    /// `.accessibilityElement(children: .combine)` for VoiceOver, which
    /// flattens any child `.accessibilityIdentifier` (including the
    /// pill's) into the combined row element, so a child identifier on
    /// the pill is unresolvable by a driver. Pill presence is therefore
    /// asserted by resolving the row via `RecentlyAdded.row(_:)` and
    /// checking its combined accessibility label contains this prefix.
    /// Kept verbatim in sync with the leading words of
    /// `RecentlyAddedViewModel.pillTitle` (`"Possible transfer"` /
    /// `"Possible transfer to <Account>"`); a divergence there must be
    /// mirrored here or the pill-presence assertion silently breaks.
    public static let pillLabelPrefix = "Possible transfer"
  }
}
