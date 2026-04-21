import SwiftUI

/// Container that presents a positions panel together with a transactions
/// list. On macOS, uses a native `NSSplitView` with an autosaved divider
/// position so the user can resize and the size sticks. On iOS, stacking
/// the two panes leaves neither with enough room, so a segmented picker
/// swaps between them.
///
/// The macOS divider position is shared across every call site (all users of
/// this container autosave under the same `NSSplitView` key). That matches
/// the Finder-sidebar convention: the user adjusts once and their preference
/// applies everywhere this component renders.
struct PositionsTransactionsSplit<Positions: View, Transactions: View>: View {
  /// The pane the iOS segmented picker selects initially. On macOS both
  /// panes are always visible in the split, so this only affects iOS.
  enum Tab { case positions, transactions }

  let defaultTab: Tab
  @ViewBuilder let positions: () -> Positions
  @ViewBuilder let transactions: () -> Transactions

  #if !os(macOS)
    @State private var selectedTab: Tab
  #endif

  init(
    defaultTab: Tab,
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
        Picker("Show", selection: $selectedTab) {
          Text("Positions").tag(Tab.positions)
          Text("Transactions").tag(Tab.transactions)
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

#Preview("Transactions-first") {
  PositionsTransactionsSplit(defaultTab: .transactions) {
    Color.blue.opacity(0.2).overlay(Text("Positions pane"))
  } transactions: {
    Color.green.opacity(0.2).overlay(Text("Transactions pane"))
  }
  .frame(width: 480, height: 480)
}

#Preview("Positions-first") {
  PositionsTransactionsSplit(defaultTab: .positions) {
    Color.blue.opacity(0.2).overlay(Text("Positions pane"))
  } transactions: {
    Color.green.opacity(0.2).overlay(Text("Transactions pane"))
  }
  .frame(width: 480, height: 480)
}
