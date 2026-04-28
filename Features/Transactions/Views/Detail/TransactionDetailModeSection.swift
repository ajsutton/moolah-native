import SwiftUI

/// User-facing transaction mode driving the simple-mode/custom-mode picker.
///
/// `expense`, `income`, `transfer`, and `trade` map onto `TransactionType` via
/// `TransactionDraft.setType(_:accounts:)` or the trade-switch helpers.
/// `custom` flips `TransactionDraft.isCustom` to switch the editor into
/// multi-leg mode. `openingBalance` legs collapse onto `.expense` for binding
/// purposes — the section disables the picker entirely for those transactions.
private enum TransactionMode: Hashable {
  case income, expense, transfer, trade, custom

  var displayName: String {
    switch self {
    case .income: return "Income"
    case .expense: return "Expense"
    case .transfer: return "Transfer"
    case .trade: return "Trade"
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
///   that can't be re-expressed as a simple income/expense/transfer/trade.
/// - The interactive `Picker` of income / expense / transfer / trade / custom.
struct TransactionDetailModeSection: View {
  let transaction: Transaction
  @Binding var draft: TransactionDraft
  let accounts: Accounts

  private var modeBinding: Binding<TransactionMode> {
    Binding(get: { modeGet() }, set: { modeSet($0) })
  }

  private func modeGet() -> TransactionMode {
    if draft.isCustom { return .custom }
    if draft.legDrafts.contains(where: { $0.type == .trade }) { return .trade }
    switch draft.type {
    case .income: return .income
    case .expense: return .expense
    case .transfer: return .transfer
    case .openingBalance: return .expense
    case .trade: return .trade
    }
  }

  private func modeSet(_ newMode: TransactionMode) {
    let wasTrade = draft.legDrafts.contains { $0.type == .trade }
    switch newMode {
    case .custom: draft.isCustom = true
    case .trade: setTradeMode(wasTrade: wasTrade)
    case .income: setSimpleMode(.income, wasTrade: wasTrade)
    case .expense: setSimpleMode(.expense, wasTrade: wasTrade)
    case .transfer: setSimpleMode(.transfer, wasTrade: wasTrade)
    }
  }

  private func setTradeMode(wasTrade: Bool) {
    if wasTrade && draft.isCustom {
      draft.isCustom = false
    } else if !wasTrade {
      draft.switchToTrade(accounts: accounts)
    }
  }

  private func setSimpleMode(_ type: TransactionType, wasTrade: Bool) {
    if wasTrade {
      draft.switchFromTrade(to: type, accounts: accounts)
    } else if draft.isCustom {
      draft.switchToSimple()
      draft.setType(type, accounts: accounts)
    } else {
      draft.setType(type, accounts: accounts)
    }
  }

  var body: some View {
    Section {
      if transaction.legs.contains(where: { $0.type == .openingBalance }) {
        LabeledContent("Type") {
          Text(TransactionType.openingBalance.displayName)
            .foregroundStyle(.secondary)
        }
      } else if !transaction.isSimple && !transaction.isTrade && !draft.isCustom {
        LabeledContent("Type") {
          Text("Custom").foregroundStyle(.secondary)
        }
        .accessibilityHint(
          "This transaction has custom sub-transactions and cannot be changed to a simpler type.")
      } else {
        Picker("Type", selection: modeBinding) {
          ForEach(
            [TransactionMode.income, .expense, .transfer, .trade, .custom], id: \.self
          ) { mode in
            Text(mode.displayName).tag(mode)
          }
        }
        .accessibilityLabel("Transaction type")
        .accessibilityIdentifier(UITestIdentifiers.Detail.modeTypePicker)
        #if os(iOS)
          .pickerStyle(.segmented)
        #endif
      }
    }
  }
}
