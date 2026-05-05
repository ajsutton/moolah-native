// Backends/GRDB/Records/PricingStatusMerge.swift

import Foundation

/// Cross-device merge rule for `TokenPricingStatus`.
///
/// CKSyncEngine's default "server wins" semantics would let the daily
/// auto-resolver on one device clobber a `.spam` classification a user
/// made on another. The merge rule below makes spam wins symmetric (user
/// intent dominates from either side) and resolution-positive (`.priced`
/// beats `.unpriced` either direction). Where the two sides agree, the
/// status is unchanged.
///
/// See `plans/2026-05-05-crypto-wallet-import-design.md` §"Cross-device
/// conflict resolution" for the truth-table that defines this contract.
enum PricingStatusMerge {
  /// Applies the cross-device merge rule and returns the resolved
  /// status to persist. Pure — no I/O — so it can be unit-tested
  /// against every cell of the 3x3 truth table without a database.
  static func merge(
    local: TokenPricingStatus,
    incoming: TokenPricingStatus
  ) -> TokenPricingStatus {
    if local == .spam || incoming == .spam { return .spam }
    if local == .priced || incoming == .priced { return .priced }
    return .unpriced
  }
}
