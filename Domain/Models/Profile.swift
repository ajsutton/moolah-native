import Foundation

enum BackendType: String, Codable, Sendable {
  case remote
  case moolah
  case cloudKit
}

struct Profile: Identifiable, Codable, Sendable, Equatable {
  static let moolahServerURL = URL(string: "https://moolah.rocks/api/")!

  let id: UUID
  var label: String
  var backendType: BackendType
  var serverURL: URL?
  var cachedUserName: String?
  var currencyCode: String
  var financialYearStartMonth: Int
  let createdAt: Date

  /// The actual server URL to connect to.
  /// Moolah profiles use the fixed moolah.rocks URL; remote profiles use their stored URL.
  var resolvedServerURL: URL {
    serverURL ?? Self.moolahServerURL
  }

  init(
    id: UUID = UUID(),
    label: String,
    backendType: BackendType = .remote,
    serverURL: URL? = nil,
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

  var instrument: Instrument {
    Instrument.fiat(code: currencyCode)
  }
}
