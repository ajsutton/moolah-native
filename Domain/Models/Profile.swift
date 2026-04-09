import Foundation

enum BackendType: String, Codable, Sendable {
  case remote
  // Future: case iCloud
}

struct Profile: Identifiable, Codable, Sendable, Equatable {
  let id: UUID
  var label: String
  var backendType: BackendType
  var serverURL: URL
  var cachedUserName: String?
  var currencyCode: String
  var financialYearStartMonth: Int
  let createdAt: Date

  init(
    id: UUID = UUID(),
    label: String,
    backendType: BackendType = .remote,
    serverURL: URL,
    cachedUserName: String? = nil,
    currencyCode: String = "AUD",
    financialYearStartMonth: Int = 7,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.label = label
    self.backendType = backendType
    self.serverURL = serverURL
    self.cachedUserName = cachedUserName
    self.currencyCode = currencyCode
    self.financialYearStartMonth = financialYearStartMonth
    self.createdAt = createdAt
  }

  var currency: Currency {
    switch currencyCode {
    case "USD": return .USD
    case "AUD": return .AUD
    default: return Currency(code: currencyCode, symbol: currencyCode, decimals: 2)
    }
  }
}
