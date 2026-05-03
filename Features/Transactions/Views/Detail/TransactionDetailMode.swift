import Foundation

/// User-facing transaction-mode selection driving the inspector's type
/// picker and the Transaction > Type menu items.
///
/// `expense`, `income`, `transfer`, and `trade` map onto `TransactionType`
/// via `TransactionDraft.setType(_:accounts:)` or the trade-switch helpers.
/// `custom` flips `TransactionDraft.isCustom` to switch the editor into
/// multi-leg mode. `openingBalance` legs collapse onto `.expense` for
/// binding purposes — `TransactionDetailModeSection` disables the picker
/// entirely for those transactions.
enum TransactionDetailMode: Hashable {
  case income
  case expense
  case transfer
  case trade
  case custom

  var displayName: String {
    switch self {
    case .income: return "Income"
    case .expense: return "Expense"
    case .transfer: return "Transfer"
    case .trade: return "Trade"
    case .custom: return "Custom"
    }
  }

  /// Form-shape grouping used to decide whether a focused amount field
  /// survives the switch to this mode.
  var focusStructure: TransactionDetailFocus.ModeStructure {
    switch self {
    case .income, .expense, .transfer: return .simple
    case .trade: return .trade
    case .custom: return .custom
    }
  }
}
