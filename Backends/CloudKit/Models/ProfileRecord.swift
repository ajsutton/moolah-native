import Foundation
import SwiftData

@Model
final class ProfileRecord {

  @Attribute(.preserveValueOnDeletion) var id = UUID()

  var label: String = ""
  var currencyCode: String = ""
  var financialYearStartMonth: Int = 7
  var createdAt = Date()
  var encodedSystemFields: Data?
  var dataFormatVersion: Int = 0

  init(
    id: UUID = UUID(),
    label: String,
    currencyCode: String,
    financialYearStartMonth: Int = 7,
    createdAt: Date = .now,
    dataFormatVersion: Int = 0
  ) {
    self.id = id
    self.label = label
    self.currencyCode = currencyCode
    self.financialYearStartMonth = financialYearStartMonth
    self.createdAt = createdAt
    self.dataFormatVersion = dataFormatVersion
  }

  func toProfile() -> Profile {
    Profile(
      id: id,
      label: label,
      currencyCode: currencyCode,
      financialYearStartMonth: financialYearStartMonth,
      createdAt: createdAt,
      dataFormatVersion: dataFormatVersion
    )
  }

  static func from(profile: Profile) -> ProfileRecord {
    ProfileRecord(
      id: profile.id,
      label: profile.label,
      currencyCode: profile.currencyCode,
      financialYearStartMonth: profile.financialYearStartMonth,
      createdAt: profile.createdAt,
      dataFormatVersion: profile.dataFormatVersion
    )
  }
}
