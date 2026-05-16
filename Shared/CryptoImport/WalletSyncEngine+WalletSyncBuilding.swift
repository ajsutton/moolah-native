import Foundation

/// `WalletSyncEngine` already exposes `build(account:chain:)` with the
/// exact `WalletSyncBuilding` signature, so the conformance is purely
/// declarative. Kept in its own file per the one-extension-per-protocol
/// convention.
extension WalletSyncEngine: WalletSyncBuilding {}
