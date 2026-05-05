import Foundation
import Testing

@testable import Moolah

@Suite("TokenPricingStatus")
struct TokenPricingStatusTests {
  @Test
  func encodesAsLowercaseString() throws {
    let encoded = try JSONEncoder().encode(TokenPricingStatus.unpriced)
    #expect(String(data: encoded, encoding: .utf8) == "\"unpriced\"")
  }

  @Test
  func decodesKnownStrings() throws {
    let priced = try JSONDecoder().decode(TokenPricingStatus.self, from: Data("\"priced\"".utf8))
    let unpriced = try JSONDecoder().decode(
      TokenPricingStatus.self, from: Data("\"unpriced\"".utf8))
    let spam = try JSONDecoder().decode(TokenPricingStatus.self, from: Data("\"spam\"".utf8))
    #expect(priced == .priced)
    #expect(unpriced == .unpriced)
    #expect(spam == .spam)
  }
}
