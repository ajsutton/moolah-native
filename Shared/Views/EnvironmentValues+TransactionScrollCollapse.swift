import SwiftUI

extension EnvironmentValues {
  /// Non-nil only when a macOS `PositionsTransactionsSplit` is hosting
  /// the transaction list and wants its header to collapse on scroll.
  /// Nil everywhere else (iOS, standalone transaction lists) — the
  /// scroll observer becomes a no-op.
  @Entry var transactionScrollCollapse: TransactionScrollCollapse?
}
