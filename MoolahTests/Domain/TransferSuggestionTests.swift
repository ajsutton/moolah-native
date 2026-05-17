import Foundation
import Testing

@testable import Moolah

@Suite("TransferSuggestion")
struct TransferSuggestionTests {
  @Test("round-trips through Codable")
  func roundTrips() throws {
    let value = TransferSuggestion(
      counterpartTransactionId: UUID(),
      suggestedAt: Date(timeIntervalSince1970: 1_700_000_000))
    let decoded = try JSONDecoder().decode(
      TransferSuggestion.self, from: JSONEncoder().encode(value))
    #expect(decoded == value)
  }
}
