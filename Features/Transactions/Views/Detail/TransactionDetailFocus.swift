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
}
