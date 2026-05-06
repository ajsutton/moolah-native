import Foundation

extension UITestIdentifiers {
  /// Identifiers for the data-format-gate stop-the-world view shown when
  /// a profile's `dataFormatVersion` exceeds `DataFormatVersion.current`
  /// (issue #764).
  public enum IncompatibleProfile {
    /// Root container of `IncompatibleProfileView`. Sentinel for the
    /// "stop-the-world incompatible-profile screen is on display"
    /// post-condition.
    public static let root = "incompatibleProfile.root"

    /// "Check for Updates" primary CTA — the user-facing affordance for
    /// the recommended remediation. Tapping it does not dismiss the
    /// view; remediation happens out-of-band (App Store update).
    public static let checkForUpdates = "incompatibleProfile.checkForUpdates"

    /// "Switch Profile" bordered CTA. Tapping it returns the user to
    /// the profile picker so they can choose a compatible profile.
    public static let switchProfile = "incompatibleProfile.switchProfile"
  }
}
