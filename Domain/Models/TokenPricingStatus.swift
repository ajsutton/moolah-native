import Foundation

/// How a crypto token's fiat value should be treated at aggregation.
/// Distinct from "rate unavailable" — `.unpriced` and `.spam` are intentional
/// zero contributions, not failures.
enum TokenPricingStatus: String, Codable, Sendable, CaseIterable {
  case priced  // provider mapping resolved; live price fetched
  case unpriced  // no provider mapping; fiat value is intentionally 0
  case spam  // user-hidden / Alchemy-flagged spam; fiat value is 0 and UI hides
}
