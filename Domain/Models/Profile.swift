import Foundation

struct Profile: Identifiable, Codable, Sendable, Equatable {
  let id: UUID
  var label: String
  var currencyCode: String
  var financialYearStartMonth: Int
  let createdAt: Date
  var dataFormatVersion: Int

  init(
    id: UUID = UUID(),
    label: String,
    currencyCode: String = "AUD",
    financialYearStartMonth: Int = 7,
    createdAt: Date = Date(),
    dataFormatVersion: Int = 0
  ) {
    self.id = id
    self.label = label
    self.currencyCode = currencyCode
    self.financialYearStartMonth = financialYearStartMonth
    self.createdAt = createdAt
    self.dataFormatVersion = dataFormatVersion
  }

  var instrument: Instrument {
    Instrument.fiat(code: currencyCode)
  }
}
