// Shared/CryptoImport/IntraAccountSwapDetector.swift
import Foundation

/// Pairs a per-event transfer leg with the direction it took relative
/// to the synced wallet. Used by `IntraAccountSwapDetector` so the
/// detector can distinguish a real inbound (`.inbound`) from a
/// self-send (`.selfSend`) without inferring from
/// `counterpartyAddress`.
struct DirectionalLeg: Sendable {
  let leg: TransactionLeg
  let direction: TransferDirection
}

/// Pure rewrite stage: when a hash group on a single account
/// represents an intra-account token swap (≥1 inbound + ≥1 outbound
/// non-fee leg, ≥2 distinct instruments across them), retype every
/// inbound and outbound leg from `.income` / `.expense` to `.trade`.
/// Otherwise return the input unchanged.
///
/// Self-send legs (`.selfSend`) and any defensively-handled
/// `.unrelated` legs are passed through untouched in their original
/// positions; their type stays whatever the builder assigned (per the
/// existing `legType(for:)` mapping `.selfSend` → `.income`).
///
/// The detector preserves order: each input position is kept; only
/// the `type` of inbound / outbound legs may be rewritten. All other
/// fields (id, accountId, instrument, quantity, externalId,
/// counterpartyAddress, categoryId, earmarkId) are preserved
/// verbatim.
///
/// Gas legs are not handled here — `TransferReceiptCoalescer.makeGasLeg`
/// runs after the detector and produces the `.expense` `:gas` leg
/// unchanged.
enum IntraAccountSwapDetector {
  static func retypeSwapLegs(_ directional: [DirectionalLeg]) -> [TransactionLeg] {
    let inbound = directional.filter { $0.direction == .inbound }
    let outbound = directional.filter { $0.direction == .outbound }
    guard !inbound.isEmpty, !outbound.isEmpty else {
      return directional.map(\.leg)
    }
    let instruments = Set(inbound.map(\.leg.instrument))
      .union(outbound.map(\.leg.instrument))
    guard instruments.count >= 2 else {
      return directional.map(\.leg)
    }
    return directional.map { item in
      switch item.direction {
      case .inbound, .outbound:
        var leg = item.leg
        leg.type = .trade
        return leg
      case .selfSend, .unrelated:
        return item.leg
      }
    }
  }
}
