import Foundation
import Testing

@testable import Moolah

@Suite("DateKey")
struct DateKeyTests {
  @Test("iso string round-trips through Int32 yyyymmdd")
  func roundTrip() {
    #expect(DateKey.from(isoString: "2024-01-15") == 20_240_115)
    #expect(DateKey.from(isoString: "1999-12-31") == 19_991_231)
    #expect(DateKey.isoString(20_240_115) == "2024-01-15")
    #expect(DateKey.isoString(19_991_231) == "1999-12-31")
  }

  @Test("malformed iso string returns nil")
  func malformed() {
    #expect(DateKey.from(isoString: "not-a-date") == nil)
    #expect(DateKey.from(isoString: "2024-13") == nil)
    #expect(DateKey.from(isoString: "") == nil)
  }

  @Test("yyyymmdd integer order equals chronological order")
  func ordering() throws {
    let dec31 = try #require(DateKey.from(isoString: "2023-12-31"))
    let jan01 = try #require(DateKey.from(isoString: "2024-01-01"))
    #expect(dec31 < jan01)
  }
}
