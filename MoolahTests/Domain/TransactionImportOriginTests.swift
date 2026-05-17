// MoolahTests/Domain/TransactionImportOriginTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("TransactionImportOrigin")
struct TransactionImportOriginTests {
  private func sample(_ tag: String) -> ImportOrigin {
    ImportOrigin(
      rawDescription: tag, rawAmount: 1, importedAt: Date(timeIntervalSince1970: 0),
      importSessionId: UUID(), parserIdentifier: "p")
  }

  @Test("single round-trips and exposes its origin")
  func single() throws {
    let origin = sample("a")
    let value = TransactionImportOrigin.single(origin)
    #expect(value.single == origin)
    #expect(value.merged == nil)
    #expect(
      try JSONDecoder().decode(
        TransactionImportOrigin.self, from: JSONEncoder().encode(value)) == value)
  }

  @Test("merged carries both sides and round-trips")
  func merged() throws {
    let value = TransactionImportOrigin.merged(
      MergedImportOrigin(outgoing: sample("out"), incoming: sample("in")))
    #expect(value.merged?.outgoing?.rawDescription == "out")
    #expect(value.merged?.incoming?.rawDescription == "in")
    #expect(value.single == nil)
    #expect(
      try JSONDecoder().decode(
        TransactionImportOrigin.self, from: JSONEncoder().encode(value)) == value)
  }
}
