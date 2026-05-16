import Foundation
import Observation

/// Turns a stream of transaction-list scroll offsets into a stable
/// collapse decision for the detail header above the list.
///
/// Hysteresis (confirmed design 2026-05-16): collapse once the user
/// scrolls past `collapseThreshold`; re-expand **only** when the list
/// is back at the top (`offsetY <= expandThreshold`). No mid-list
/// re-expansion — that produced jitter in earlier explorations.
@MainActor
@Observable
final class TransactionScrollCollapse {
  private(set) var isCollapsed = false

  private let collapseThreshold: CGFloat
  private let expandThreshold: CGFloat

  init(collapseThreshold: CGFloat = 44, expandThreshold: CGFloat = 1) {
    self.collapseThreshold = collapseThreshold
    self.expandThreshold = expandThreshold
  }

  func update(offsetY: CGFloat) {
    if isCollapsed {
      if offsetY <= expandThreshold { isCollapsed = false }
    } else if offsetY > collapseThreshold {
      isCollapsed = true
    }
  }

  func reset() {
    isCollapsed = false
  }
}
