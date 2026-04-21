import SwiftUI

/// Container that presents a positions panel together with a transactions
/// list. On macOS, uses a native `NSSplitView` with an autosaved divider
/// position so the user can resize and the size sticks. On iOS, stacking
/// the two panes leaves neither with enough room, so a segmented picker
/// swaps between them.
struct PositionsTransactionsSplit<Positions: View, Transactions: View>: View {
  enum DefaultTab { case positions, transactions }

  let defaultTab: DefaultTab
  @ViewBuilder let positions: () -> Positions
  @ViewBuilder let transactions: () -> Transactions

  #if !os(macOS)
    @State private var selectedTab: DefaultTab
  #endif

  init(
    defaultTab: DefaultTab,
    @ViewBuilder positions: @escaping () -> Positions,
    @ViewBuilder transactions: @escaping () -> Transactions
  ) {
    self.defaultTab = defaultTab
    self.positions = positions
    self.transactions = transactions
    #if !os(macOS)
      _selectedTab = State(initialValue: defaultTab)
    #endif
  }

  var body: some View {
    #if os(macOS)
      ResizableVSplit(
        autosaveName: "positions-transactions-split",
        initialTopHeight: 180
      ) {
        positions()
      } bottom: {
        transactions()
      }
    #else
      VStack(spacing: 0) {
        Picker("View", selection: $selectedTab) {
          Text("Positions").tag(DefaultTab.positions)
          Text("Transactions").tag(DefaultTab.transactions)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.vertical, 8)

        Divider()

        switch selectedTab {
        case .positions: positions()
        case .transactions: transactions()
        }
      }
    #endif
  }
}

#Preview("Default: transactions") {
  PositionsTransactionsSplit(defaultTab: .transactions) {
    Color.blue.opacity(0.2).overlay(Text("Positions pane"))
  } transactions: {
    Color.green.opacity(0.2).overlay(Text("Transactions pane"))
  }
  .frame(width: 480, height: 480)
}

#Preview("Default: positions") {
  PositionsTransactionsSplit(defaultTab: .positions) {
    Color.blue.opacity(0.2).overlay(Text("Positions pane"))
  } transactions: {
    Color.green.opacity(0.2).overlay(Text("Transactions pane"))
  }
  .frame(width: 480, height: 480)
}
