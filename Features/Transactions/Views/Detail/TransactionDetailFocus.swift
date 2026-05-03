import SwiftUI

/// Focus targets for fields rendered across `TransactionDetailView`'s child
/// sections. Lives outside the parent struct so the leg-row subview can
/// drive a `@FocusState.Binding` for `.legAmount(index)` without owning the
/// enum itself.
enum TransactionDetailFocus: Hashable {
  case payee
  case amount
  case counterpartAmount
  case legAmount(Int)
  case tradePaidAmount
  case tradeReceivedAmount
  case tradeFeeAmount(Int)  // index into legDrafts

  /// Higher-level grouping of transaction modes by the shape of their
  /// form. Income, Expense, and Transfer share one focus surface
  /// (`.amount` / `.counterpartAmount`); Trade and Custom each have their
  /// own. The shortcut-driven type switcher uses this enum to decide
  /// whether the focused field still exists in the new mode and where to
  /// remap it otherwise.
  enum ModeStructure: Hashable {
    case simple
    case trade
    case custom
  }
}
