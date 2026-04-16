import Foundation

enum TransactionDraftHelpers {
  /// Filter accounts to those matching the given currency, for the "To Account" picker
  /// in simple transfer mode.
  static func eligibleToAccounts(from accounts: Accounts, currency: Instrument) -> [Account] {
    accounts.ordered.filter { $0.instrument == currency }
  }
}
