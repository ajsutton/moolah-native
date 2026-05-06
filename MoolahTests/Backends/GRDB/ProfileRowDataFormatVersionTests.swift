import Foundation
import Testing

@testable import Moolah

@Suite("ProfileRow — dataFormatVersion plumbing")
struct ProfileRowDataFormatVersionTests {
  @Test("init(domain:) carries dataFormatVersion through")
  func mappingFromDomain() {
    let profile = Profile(label: "Carries", dataFormatVersion: 1)
    let row = ProfileRow(domain: profile)
    #expect(row.dataFormatVersion == 1)
  }

  @Test("toDomain() carries dataFormatVersion through")
  func mappingToDomain() {
    let row = ProfileRow(
      id: UUID(),
      recordName: "ProfileRecord|abc",
      label: "Carries",
      currencyCode: "AUD",
      financialYearStartMonth: 7,
      createdAt: Date(),
      encodedSystemFields: nil,
      dataFormatVersion: 1)
    #expect(row.toDomain().dataFormatVersion == 1)
  }

  @Test("Columns and CodingKeys both expose dataFormatVersion")
  func columnsAndCodingKeysAlign() {
    #expect(ProfileRow.Columns.dataFormatVersion.rawValue == "data_format_version")
    #expect(ProfileRow.CodingKeys.dataFormatVersion.rawValue == "data_format_version")
  }
}
