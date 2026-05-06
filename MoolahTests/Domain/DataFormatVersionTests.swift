import Foundation
import Testing

@testable import Moolah

@Suite("DataFormatVersion")
struct DataFormatVersionTests {
  @Test("current is at least 1 — the gate has shipped")
  func currentIsAtLeastOne() {
    #expect(DataFormatVersion.current >= 1)
  }

  @Test("Profile gets a default dataFormatVersion of 0 — pre-gate baseline")
  func profileDefaultsToZero() {
    let profile = Profile(label: "Test")
    #expect(profile.dataFormatVersion == 0)
  }
}
