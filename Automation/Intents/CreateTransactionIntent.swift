import AppIntents
import Foundation

struct CreateTransactionIntent: AppIntent {
  static let title: LocalizedStringResource = "Add Transaction"
  static let description = IntentDescription(
    "Creates a new transaction in the specified account.")

  @Parameter(title: "Profile")
  var profile: ProfileEntity

  @Parameter(title: "Payee")
  var payee: String

  @Parameter(title: "Amount")
  var amount: Double

  @Parameter(title: "Account")
  var account: AccountEntity

  @Parameter(title: "Category", default: nil)
  var category: CategoryEntity?

  @Parameter(title: "Date", default: nil)
  var date: Date?

  @MainActor
  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    guard let service = AutomationServiceLocator.shared.service else {
      throw AutomationError.operationFailed("App not ready")
    }

    let transactionDate = date ?? Date()
    let decimalAmount = Decimal(amount)

    // Request confirmation before creating the transaction
    let formattedAmount = String(format: "%.2f", amount)
    try await requestConfirmation(
      dialog: "Create transaction: \(payee) for \(formattedAmount) in \(account.name)?"
    )

    let leg = AutomationService.LegSpec(
      accountName: account.name,
      amount: decimalAmount,
      categoryName: category?.name,
      earmarkName: nil
    )

    let transaction = try await service.createTransaction(
      profileIdentifier: profile.id.uuidString,
      payee: payee,
      date: transactionDate,
      legs: [leg]
    )

    let displayPayee = transaction.payee ?? payee
    return .result(value: "Created transaction: \(displayPayee)")
  }
}
