import Foundation

/// Sort columns surfaced by the macOS positions Grid (spec §1).
/// Matches the existing production `Table` column set so the wide
/// layout's sort semantics survive the Grid rewrite.
enum PositionsSortColumn: String, Hashable, CaseIterable {
  case instrument
  case quantity
  case unitPrice
  case costBasis
  case value
  case gain
}

enum PositionsSortDirection: Hashable {
  case ascending
  case descending
}

/// Pure value type carrying the active sort column + direction for the
/// positions Grid. Per spec §1.3: tapping an inactive column activates
/// it descending; tapping the active column flips direction; sort
/// never resets to "no sort." Lives outside any view so the cycle is
/// unit-testable without SwiftUI rendering.
struct PositionsSortState: Hashable {
  private(set) var column: PositionsSortColumn
  private(set) var direction: PositionsSortDirection

  init(column: PositionsSortColumn = .value, direction: PositionsSortDirection = .descending) {
    self.column = column
    self.direction = direction
  }

  /// Per spec §1.3:
  /// - Tap inactive column → activate it, `direction = .descending`
  ///   ("largest first" — the existing production default with
  ///   `\.valueQuantity, order: .reverse`).
  /// - Tap active column → flip direction.
  /// - Sort never resets to "no sort" — there is always an active column.
  ///
  /// Deliberate macOS HIG deviation: convention is ascending-on-first-
  /// activation (Finder/Mail). We use descending-on-first-activation
  /// because "largest first" is the more useful default for monetary
  /// columns. Do not "correct" this — see spec §1.3.
  mutating func toggleSort(_ tapped: PositionsSortColumn) {
    if tapped == column {
      direction = (direction == .ascending) ? .descending : .ascending
    } else {
      column = tapped
      direction = .descending
    }
  }

  /// Sort `rows` by the active column/direction. `nil` values for the
  /// chosen column sink to the end regardless of direction (per spec §1:
  /// "the gain column shows the full signed-and-percent value without
  /// truncation" — missing-gain rows are a UX edge, not a sort key).
  func sorted(_ rows: [ValuedPosition]) -> [ValuedPosition] {
    let ascending = direction == .ascending
    return rows.sorted { left, right in
      let leftKey = key(for: left)
      let rightKey = key(for: right)
      switch (leftKey, rightKey) {
      case let (.some(lhs), .some(rhs)):
        return ascending ? lhs < rhs : lhs > rhs
      case (.some, .none):
        return true  // values before nils, regardless of direction
      case (.none, .some):
        return false
      case (.none, .none):
        // Tiebreak by instrument id so the relative order is stable
        // across re-renders. Same fallback applies whenever the chosen
        // column's values are equal.
        return left.instrument.id < right.instrument.id
      }
    }
  }

  private func key(for row: ValuedPosition) -> SortKey? {
    switch column {
    case .instrument:
      return .string(row.instrument.name)
    case .quantity:
      return .decimal(row.quantity)
    case .unitPrice:
      return row.unitPrice.map { .decimal($0.quantity) }
    case .costBasis:
      return row.costBasis.map { .decimal($0.quantity) }
    case .value:
      return row.value.map { .decimal($0.quantity) }
    case .gain:
      return row.gainLoss.map { .decimal($0.quantity) }
    }
  }

  /// Comparable wrapper so the keys for the six columns share one
  /// generic sort path. Decimal and String are both `Comparable`; the
  /// wrapper unifies them under one comparable type.
  private enum SortKey: Comparable {
    case decimal(Decimal)
    case string(String)

    static func < (lhs: SortKey, rhs: SortKey) -> Bool {
      switch (lhs, rhs) {
      case let (.decimal(leftValue), .decimal(rightValue)):
        return leftValue < rightValue
      case let (.string(leftValue), .string(rightValue)):
        return leftValue.localizedStandardCompare(rightValue) == .orderedAscending
      // Mixed cases are never produced by `key(for:)` for a given column.
      // Trapping makes the assumption explicit; the function is internal
      // so call sites are auditable.
      case (.decimal, .string), (.string, .decimal):
        preconditionFailure("PositionsSortState.SortKey: heterogeneous comparison")
      }
    }
  }
}
