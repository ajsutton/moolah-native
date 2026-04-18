import AppIntents
import Foundation

struct GetExpenseBreakdownIntent: AppIntent {
  static let title: LocalizedStringResource = "Expense Breakdown"
  static let description = IntentDescription(
    "Shows a breakdown of expenses by category for a given period.")

  @Parameter(title: "Profile")
  var profile: ProfileEntity

  @Parameter(title: "Period", default: .thisMonth)
  var period: ExpensePeriod

  @MainActor
  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    guard let service = AutomationServiceLocator.shared.service else {
      throw AutomationError.operationFailed("App not ready")
    }

    let targetMonth = period.targetMonth
    let analysisData = try await service.loadAnalysis(
      profileIdentifier: profile.id.uuidString,
      historyMonths: 2
    )

    let breakdown = analysisData.expenseBreakdown.filter { $0.month == targetMonth }

    if breakdown.isEmpty {
      return .result(value: "No expenses found for \(period.displayLabel).")
    }

    // Resolve category names
    let categories = try service.listCategories(profileIdentifier: profile.id.uuidString)
    let categoryLookup = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0.name) })

    let lines =
      breakdown
      .sorted { $0.totalExpenses > $1.totalExpenses }
      .map { item in
        let categoryName = item.categoryId.flatMap { categoryLookup[$0] } ?? "Uncategorized"
        return "\(categoryName): \(item.totalExpenses.formatted)"
      }

    let total = breakdown.reduce(
      InstrumentAmount.zero(instrument: breakdown[0].totalExpenses.instrument)
    ) { $0 + $1.totalExpenses }

    return .result(
      value:
        "\(period.displayLabel) expenses:\n\(lines.joined(separator: "\n"))\nTotal: \(total.formatted)"
    )
  }
}

enum ExpensePeriod: String, AppEnum {
  case thisMonth
  case lastMonth

  static let typeDisplayRepresentation = TypeDisplayRepresentation(
    name: "Period")

  static let caseDisplayRepresentations: [ExpensePeriod: DisplayRepresentation] = [
    .thisMonth: "This Month",
    .lastMonth: "Last Month",
  ]

  var displayLabel: String {
    switch self {
    case .thisMonth: "This month"
    case .lastMonth: "Last month"
    }
  }

  var targetMonth: String {
    let calendar = Calendar.current
    let date: Date
    switch self {
    case .thisMonth:
      date = Date()
    case .lastMonth:
      date = calendar.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    }
    let year = calendar.component(.year, from: date)
    let month = calendar.component(.month, from: date)
    return String(format: "%04d%02d", year, month)
  }
}
