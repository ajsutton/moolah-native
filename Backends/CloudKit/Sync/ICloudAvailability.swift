import Foundation

/// Current observability-oriented view of iCloud account status for
/// Moolah's CloudKit sync.
///
/// Source of truth lives on ``SyncCoordinator`` — see
/// `guides/SYNC_GUIDE.md` Rule 8 (single owner for account-change
/// handling). Views read through ``ProfileStore.iCloudAvailability``
/// which is a pass-through.
///
/// `.unknown` is the initial state before the first `accountStatus()`
/// probe has returned, **and** the state we fall back to on
/// `CKAccountStatus.couldNotDetermine` or a thrown probe error. We
/// deliberately treat these as transient and keep the welcome screen's
/// "Checking iCloud…" copy running — see design spec §6.1 and §8.
enum ICloudAvailability: Equatable, Sendable {
  case unknown
  case available
  case unavailable(reason: UnavailableReason)

  /// Why iCloud is unavailable right now. Surfaced to view code for
  /// copy selection (see `WelcomeView`'s iCloud-off chip variants).
  enum UnavailableReason: Equatable, Sendable {
    /// `CKAccountStatus.noAccount` — user is not signed into iCloud.
    case notSignedIn
    /// `CKAccountStatus.restricted` — parental controls / MDM.
    case restricted
    /// `CKAccountStatus.temporarilyUnavailable` — iCloud is reachable
    /// but the account is in a temporary bad state.
    case temporarilyUnavailable
    /// `CloudKitAuthProvider.isCloudKitAvailable == false` — the build
    /// is missing the iCloud entitlements (dev / CI builds).
    case entitlementsMissing
  }
}
