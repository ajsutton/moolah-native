import Foundation

enum BackendType: String, Codable, Sendable {
  case remote
  case moolah
  case cloudKit
}

struct Profile: Identifiable, Codable, Sendable, Equatable {
  static let moolahServerURL =
    URL(string: "https://moolah.rocks/api/") ?? URL(fileURLWithPath: "/")

  let id: UUID
  var label: String
  var backendType: BackendType
  var serverURL: URL?
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
    currencyCode: String = "AUD",
    financialYearStartMonth: Int = 7,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.label = label
    self.backendType = backendType
    self.serverURL = serverURL
    self.currencyCode = currencyCode
    self.financialYearStartMonth = financialYearStartMonth
    self.createdAt = createdAt
  }

  var instrument: Instrument {
    Instrument.fiat(code: currencyCode)
  }

  /// Whether this profile's backend supports multi-instrument data:
  /// per-account currencies, per-earmark currencies, cross-currency transfers,
  /// and the custom transaction editor with per-leg instrument overrides.
  ///
  /// `true` only for `.cloudKit`. `Remote` and `moolah` backends are
  /// single-instrument — every account, earmark, and transaction leg must be
  /// in `profile.currencyCode`. UI must gate currency pickers and custom mode
  /// on this flag; `Remote*Repository` write paths enforce the constraint via
  /// `requireMatchesProfileInstrument(...)` (see
  /// `guides/INSTRUMENT_CONVERSION_GUIDE.md` Rule 11a).
  var supportsComplexTransactions: Bool {
    backendType == .cloudKit
  }
}
