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

  init(
    id: UUID = UUID(),
    label: String,
    currencyCode: String,
    financialYearStartMonth: Int = 7,
    createdAt: Date = .now
  ) {
    self.id = id
    self.label = label
    self.currencyCode = currencyCode
    self.financialYearStartMonth = financialYearStartMonth
    self.createdAt = createdAt
  }

  func toProfile() -> Profile {
    Profile(
      id: id,
      label: label,
      backendType: .cloudKit,
      currencyCode: currencyCode,
      financialYearStartMonth: financialYearStartMonth,
      createdAt: createdAt
    )
  }

  static func from(profile: Profile) -> ProfileRecord {
    ProfileRecord(
      id: profile.id,
      label: profile.label,
      currencyCode: profile.currencyCode,
      financialYearStartMonth: profile.financialYearStartMonth,
      createdAt: profile.createdAt
    )
  }
}
