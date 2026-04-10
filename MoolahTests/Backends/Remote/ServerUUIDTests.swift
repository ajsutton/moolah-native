import Foundation
import Testing

@testable import Moolah

struct ServerUUIDTests {
  let testUUID = UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")!

  @Test func encodesToLowercaseJSON() throws {
    let serverUUID = ServerUUID(testUUID)
    let data = try JSONEncoder().encode(serverUUID)
    let json = String(data: data, encoding: .utf8)!
    #expect(json == "\"e621e1f8-c36c-495a-93fc-0c247a3e6e5f\"")
  }

  @Test func uuidStringIsLowercase() {
    let serverUUID = ServerUUID(testUUID)
    #expect(serverUUID.uuidString == "e621e1f8-c36c-495a-93fc-0c247a3e6e5f")
  }

  @Test func decodesLowercaseUUID() throws {
    let json = "\"e621e1f8-c36c-495a-93fc-0c247a3e6e5f\""
    let data = json.data(using: .utf8)!
    let result = try JSONDecoder().decode(ServerUUID.self, from: data)
    #expect(result.uuid == testUUID)
  }

  @Test func decodesUppercaseUUID() throws {
    let json = "\"E621E1F8-C36C-495A-93FC-0C247A3E6E5F\""
    let data = json.data(using: .utf8)!
    let result = try JSONDecoder().decode(ServerUUID.self, from: data)
    #expect(result.uuid == testUUID)
  }

  @Test func decodesUnhyphenatedUUID() throws {
    let json = "\"e621e1f8c36c495a93fc0c247a3e6e5f\""
    let data = json.data(using: .utf8)!
    let result = try JSONDecoder().decode(ServerUUID.self, from: data)
    #expect(result.uuid == testUUID)
  }

  @Test func roundTripPreservesUUID() throws {
    let original = ServerUUID(testUUID)
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(ServerUUID.self, from: data)
    #expect(decoded.uuid == original.uuid)
  }

  @Test func optionalNullDecodesAsNil() throws {
    let json = "null"
    let data = json.data(using: .utf8)!
    let result = try JSONDecoder().decode(ServerUUID?.self, from: data)
    #expect(result == nil)
  }

  @Test func apiStringExtensionIsLowercase() {
    let uuid = UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")!
    #expect(uuid.apiString == "e621e1f8-c36c-495a-93fc-0c247a3e6e5f")
  }
}
