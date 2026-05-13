import Foundation

/// Sort columns surfaced by the macOS positions Grid. Matches the
/// existing production `Table` column set so the wide layout's sort
/// semantics survive the Grid rewrite.
enum PositionsSortColumn: String {
  case instrument
  case quantity
  case unitPrice
  case costBasis
  case value
  case gain
}

extension PositionsSortColumn: Hashable {}

extension PositionsSortColumn: CaseIterable {}

enum PositionsSortDirection {
  case ascending
  case descending
}

extension PositionsSortDirection: Hashable {}

/// Pure value type carrying the active sort column + direction. Tapping
/// an inactive column activates it descending; tapping the active column
/// flips direction; sort never resets to "no sort." Lives outside any
/// view so the cycle is unit-testable without SwiftUI rendering.
struct PositionsSortState {
  private(set) var column: PositionsSortColumn
  private(set) var direction: PositionsSortDirection

  init(column: PositionsSortColumn = .value, direction: PositionsSortDirection = .descending) {
    self.column = column
    self.direction = direction
  }

  /// Sort-state cycle:
  /// - Tap inactive column → activate it, `direction = .descending`
  ///   ("largest first" — the existing production default with
  ///   `\.valueQuantity, order: .reverse`).
  /// - Tap active column → flip direction.
  /// - Sort never resets to "no sort" — there is always an active column.
  ///
  /// Deliberate macOS HIG deviation: convention is ascending-on-first-
  /// activation (Finder/Mail). We use descending-on-first-activation
  /// because "largest first" is the more useful default for monetary
  /// columns. Do not "correct" this.
  mutating func toggleSort(_ tapped: PositionsSortColumn) {
    if tapped == column {
      direction = (direction == .ascending) ? .descending : .ascending
    } else {
      column = tapped
      direction = .descending
    }
  }

  /// Sort `rows` by the active column/direction. `nil` values for the
  /// chosen column sink to the end regardless of direction (missing-key
  /// rows are a UX edge, not a sort key). Equal keys tiebreak on
  /// `instrument.id` so order is stable across re-renders even when
  /// CloudKit sync redelivers rows in a different source order.
  func sorted(_ rows: [ValuedPosition]) -> [ValuedPosition] {
    let ascending = direction == .ascending
    return rows.sorted { left, right in
      let leftKey = key(for: left)
      let rightKey = key(for: right)
      switch (leftKey, rightKey) {
      case let (.some(lhs), .some(rhs)):
        // Equal keys tiebreak on instrument.id so order is stable
        // across re-renders.
        if lhs == rhs {
          return left.instrument.id < right.instrument.id
        }
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
  ///
  /// Not marked `private` so the `Comparable` conformance can live in
  /// a file-scope extension (CODE_GUIDE.md §11: one protocol per
  /// extension, no inline conformance list). The type stays nested
  /// inside `PositionsSortState` and is never referenced outside this
  /// file — the relaxed access modifier is a Swift-mechanics
  /// concession, not an intentional API surface.
  enum SortKey {
    case decimal(Decimal)
    case string(String)
  }
}

extension PositionsSortState: Hashable {}

extension PositionsSortState.SortKey: Equatable {}

extension PositionsSortState.SortKey: Comparable {
  static func < (lhs: Self, rhs: Self) -> Bool {
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
