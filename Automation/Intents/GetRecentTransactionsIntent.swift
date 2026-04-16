import AppIntents
import Foundation

struct GetRecentTransactionsIntent: AppIntent {
  nonisolated(unsafe) static var title: LocalizedStringResource = "Recent Transactions"
  nonisolated(unsafe) static var description = IntentDescription(
    "Shows recent transactions, optionally filtered by account.")

  @Parameter(title: "Profile")
  var profile: ProfileEntity

  @Parameter(title: "Account", default: nil)
  var account: AccountEntity?

  @Parameter(title: "Count", default: 5)
  var count: Int

  @MainActor
  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    guard let service = AutomationServiceLocator.shared.service else {
      throw AutomationError.operationFailed("App not ready")
    }

    let transactions = try await service.listTransactions(
      profileIdentifier: profile.id.uuidString,
      accountName: account?.name,
      scheduled: false
    )

    let recent = Array(transactions.prefix(count))

    if recent.isEmpty {
      return .result(value: "No recent transactions.")
    }

    let dateFormatter = DateFormatter()
    dateFormatter.dateStyle = .short

    let lines = recent.map { transaction in
      let payee = transaction.payee ?? "Unknown"
      let dateStr = dateFormatter.string(from: transaction.date)
      let totalAmount = transaction.legs.reduce(Decimal.zero) { $0 + $1.quantity }
      let amountStr =
        transaction.legs.first.map { leg in
          InstrumentAmount(quantity: totalAmount, instrument: leg.instrument).formatted
        } ?? String(describing: totalAmount)
      return "\(dateStr) \(payee): \(amountStr)"
    }
    return .result(value: lines.joined(separator: "\n"))
  }
}
