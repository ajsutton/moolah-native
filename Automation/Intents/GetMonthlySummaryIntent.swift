import AppIntents
import Foundation

struct GetMonthlySummaryIntent: AppIntent {
  nonisolated(unsafe) static var title: LocalizedStringResource = "Monthly Summary"
  nonisolated(unsafe) static var description = IntentDescription(
    "Returns a summary of income, expenses, and net for a given month.")

  @Parameter(title: "Profile")
  var profile: ProfileEntity

  @Parameter(title: "Month", default: 1)
  var month: Int

  @Parameter(title: "Year", default: 2026)
  var year: Int

  @MainActor
  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    guard let service = AutomationServiceLocator.shared.service else {
      throw AutomationError.operationFailed("App not ready")
    }

    let targetMonth = String(format: "%04d%02d", year, month)
    let analysisData = try await service.loadAnalysis(
      profileIdentifier: profile.id.uuidString,
      historyMonths: 13
    )

    guard let summary = analysisData.incomeAndExpense.first(where: { $0.month == targetMonth })
    else {
      return .result(
        value: "No data found for \(monthName(month)) \(year).")
    }

    return .result(
      value: """
        \(monthName(month)) \(year) Summary:
        Income: \(summary.totalIncome.formatted)
        Expenses: \(summary.totalExpense.formatted)
        Net: \(summary.totalProfit.formatted)
        """)
  }

  private func monthName(_ month: Int) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "MMMM"
    var components = DateComponents()
    components.month = month
    components.day = 1
    components.year = 2026
    guard let date = Calendar.current.date(from: components) else { return "Unknown" }
    return formatter.string(from: date)
  }
}
