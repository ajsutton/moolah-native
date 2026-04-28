import SwiftUI

/// User-facing transaction mode driving the simple-mode/custom-mode picker.
///
/// `expense`, `income`, and `transfer` map onto `TransactionType` via
/// `TransactionDraft.setType(_:accounts:)`. `custom` flips
/// `TransactionDraft.isCustom` to switch the editor into multi-leg mode.
/// `openingBalance` legs collapse onto `.expense` for binding purposes — the
/// section disables the picker entirely for those transactions.
private enum TransactionMode: Hashable {
  case income, expense, transfer, custom

  var displayName: String {
    switch self {
    case .income: return "Income"
    case .expense: return "Expense"
    case .transfer: return "Transfer"
    case .custom: return "Custom"
    }
  }
}

/// The "Type" picker section.
///
/// Renders one of three forms depending on the underlying transaction:
/// - Read-only "Opening balance" label when any leg is an opening balance
///   (the user can't change the type of the seed transaction).
/// - Read-only "Custom" label when the transaction has multi-leg structure
///   that can't be re-expressed as a simple income/expense/transfer.
/// - The interactive `Picker` of income/expense/transfer/custom modes.
struct TransactionDetailModeSection: View {
  let transaction: Transaction
  @Binding var draft: TransactionDraft
  let accounts: Accounts

  private var modeBinding: Binding<TransactionMode> {
    Binding(
      get: {
        if draft.isCustom { return .custom }
        switch draft.type {
        case .income: return .income
        case .expense: return .expense
        case .transfer: return .transfer
        case .openingBalance: return .expense
        }
      },
      set: { newMode in
        switch newMode {
        case .custom:
          draft.isCustom = true
        case .income:
          if draft.isCustom { draft.switchToSimple() }
          draft.setType(.income, accounts: accounts)
        case .expense:
          if draft.isCustom { draft.switchToSimple() }
          draft.setType(.expense, accounts: accounts)
        case .transfer:
          if draft.isCustom { draft.switchToSimple() }
          draft.setType(.transfer, accounts: accounts)
        }
      }
    )
  }

  var body: some View {
    Section {
      if transaction.legs.contains(where: { $0.type == .openingBalance }) {
        LabeledContent("Type") {
          Text(TransactionType.openingBalance.displayName)
            .foregroundStyle(.secondary)
        }
      } else if !transaction.isSimple {
        LabeledContent("Type") {
          Text("Custom")
            .foregroundStyle(.secondary)
        }
        .accessibilityHint(
          "This transaction has custom sub-transactions and cannot be changed to a simpler type.")
      } else {
        Picker("Type", selection: modeBinding) {
          ForEach([TransactionMode.income, .expense, .transfer, .custom], id: \.self) { mode in
            Text(mode.displayName).tag(mode)
          }
        }
        .accessibilityLabel("Transaction type")
        #if os(iOS)
          .pickerStyle(.segmented)
        #endif
      }
    }
  }
}
