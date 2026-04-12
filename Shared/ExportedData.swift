import Foundation

/// All data exported from a profile, ready for serialization or import into SwiftData.
struct ExportedData: Codable, Sendable {
  let version: Int
  let exportedAt: Date
  let profileLabel: String
  let currencyCode: String
  let financialYearStartMonth: Int
  let accounts: [Account]
  let categories: [Category]
  let earmarks: [Earmark]
  let earmarkBudgets: [UUID: [EarmarkBudgetItem]]
  let transactions: [Transaction]
  let investmentValues: [UUID: [InvestmentValue]]

  init(
    version: Int = 1,
    exportedAt: Date = Date(),
    profileLabel: String = "",
    currencyCode: String = "",
    financialYearStartMonth: Int = 1,
    accounts: [Account],
    categories: [Category],
    earmarks: [Earmark],
    earmarkBudgets: [UUID: [EarmarkBudgetItem]],
    transactions: [Transaction],
    investmentValues: [UUID: [InvestmentValue]]
  ) {
    self.version = version
    self.exportedAt = exportedAt
    self.profileLabel = profileLabel
    self.currencyCode = currencyCode
    self.financialYearStartMonth = financialYearStartMonth
    self.accounts = accounts
    self.categories = categories
    self.earmarks = earmarks
    self.earmarkBudgets = earmarkBudgets
    self.transactions = transactions
    self.investmentValues = investmentValues
  }
}

extension JSONEncoder {
  static var exportEncoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }
}

extension JSONDecoder {
  static var exportDecoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
