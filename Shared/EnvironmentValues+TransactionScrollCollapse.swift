import SwiftUI

extension EnvironmentValues {
  /// Injected by the macOS `PositionsTransactionsSplit` when it hosts the
  /// transaction list and wants its header to collapse on scroll.
  /// `nil` everywhere else (iOS, standalone transaction lists) — the
  /// scroll observer becomes a no-op.
  @Entry var transactionScrollCollapse: TransactionScrollCollapse?
}
