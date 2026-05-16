import SwiftUI

/// Container that presents a positions panel together with a transactions
/// list. On macOS, uses a native `NSSplitView` with an autosaved divider
/// position so the user can resize and the size sticks. On iOS, stacking
/// the two panes leaves neither with enough room, so a segmented picker
/// swaps between them.
///
/// Two layouts coexist and must NOT share a divider:
///   - **Chartless** (default, used by multi-currency non-investment accounts):
///     header + table only. ~180pt is plenty for several rows.
///   - **With chart** (investment accounts in `.calculatedFromTrades`):
///     header + chart (220pt fixed) + table. ~180pt clips the table below
///     the chart so it appears empty unless the user drags the divider —
///     hence a separate, taller default and a distinct autosave key.
///
/// Within a layout, the divider position is autosaved and shared across all
/// call sites — Finder-sidebar style: adjust once, applies everywhere of
/// the same shape.
struct PositionsTransactionsSplit<Positions: View, Transactions: View>: View {
  /// The pane the iOS segmented picker selects initially. On macOS both
  /// panes are always visible in the split, so this only affects iOS.
  enum Tab { case positions, transactions }

  let defaultTab: Tab
  let autosaveName: String
  let initialTopHeight: CGFloat
  @ViewBuilder let positions: () -> Positions
  @ViewBuilder let transactions: () -> Transactions

  #if os(macOS)
    @State private var scrollCollapse = TransactionScrollCollapse()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
  #endif

  #if !os(macOS)
    @State private var selectedTab: Tab
  #endif

  init(
    defaultTab: Tab,
    autosaveName: String = "positions-transactions-split",
    initialTopHeight: CGFloat = 180,
    @ViewBuilder positions: @escaping () -> Positions,
    @ViewBuilder transactions: @escaping () -> Transactions
  ) {
    self.defaultTab = defaultTab
    self.autosaveName = autosaveName
    self.initialTopHeight = initialTopHeight
    self.positions = positions
    self.transactions = transactions
    #if !os(macOS)
      _selectedTab = State(initialValue: defaultTab)
    #endif
  }

  var body: some View {
    #if os(macOS)
      ResizableVSplit(
        autosaveName: autosaveName,
        initialTopHeight: initialTopHeight,
        collapsed: scrollCollapse.isCollapsed,
        reduceMotion: reduceMotion
      ) {
        positions()
      } bottom: {
        transactions()
          .environment(\.transactionScrollCollapse, scrollCollapse)
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
