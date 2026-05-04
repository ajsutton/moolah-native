import Foundation

/// Selects how an investment account's "current value" is computed for
/// balance display, totals, and reports.
///
/// - `recordedValue`: the latest user-entered `InvestmentValue` snapshot
///   drives the displayed value. Snapshots are edited via the legacy
///   investment-account view.
/// - `calculatedFromTrades`: the value is computed by summing positions
///   (derived from trade transactions) at current instrument prices.
///
/// The mode is a per-`Account` setting; switching is reversible.
/// See `plans/2026-05-04-per-account-valuation-mode-design.md`.
enum ValuationMode: String, Codable, Sendable, CaseIterable {
  case recordedValue
  case calculatedFromTrades
}
