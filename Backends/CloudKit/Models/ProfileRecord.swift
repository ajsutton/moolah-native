import Foundation
import SwiftData

@Model
final class ProfileRecord {
  #Unique<ProfileRecord>([\.id])

  @Attribute(.preserveValueOnDeletion)
  var id: UUID

  var label: String
  var currencyCode: String
  var financialYearStartMonth: Int
  var createdAt: Date

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
