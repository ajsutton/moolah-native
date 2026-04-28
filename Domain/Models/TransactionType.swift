import Foundation

enum TransactionType: String, Codable, Sendable, CaseIterable {
  case income
  case expense
  case transfer
  case openingBalance
  case trade

  /// Whether this transaction type can be manually created or edited by users.
  /// Opening balance transactions are system-generated and cannot be modified.
  var isUserEditable: Bool {
    self != .openingBalance
  }

  /// Display name for the transaction type
  var displayName: String {
    switch self {
    case .income: return "Income"
    case .expense: return "Expense"
    case .transfer: return "Transfer"
    case .openingBalance: return "Opening Balance"
    case .trade: return "Trade"
    }
  }

  /// Only types that users can select when creating/editing transactions
  static var userSelectableTypes: [TransactionType] {
    [.income, .expense, .transfer, .trade]
  }
}
