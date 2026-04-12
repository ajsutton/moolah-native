// MoolahTests/Domain/CryptoTokenRepositoryTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("CryptoTokenRepository (InMemory)")
struct CryptoTokenRepositoryTests {
  private func makeRepository() -> InMemoryTokenRepository {
    InMemoryTokenRepository()
  }

  @Test func emptyRepositoryReturnsEmptyArray() async throws {
    let repo = makeRepository()
    let tokens = try await repo.loadTokens()
    #expect(tokens.isEmpty)
  }

  @Test func roundTrip_saveAndLoad() async throws {
    let repo = makeRepository()
    let tokens = Array(CryptoToken.builtInPresets.prefix(2))
    try await repo.saveTokens(tokens)
    let loaded = try await repo.loadTokens()
    #expect(loaded.count == 2)
    #expect(loaded[0].id == tokens[0].id)
    #expect(loaded[1].id == tokens[1].id)
  }

  @Test func saveOverwritesPreviousList() async throws {
    let repo = makeRepository()
    try await repo.saveTokens(Array(CryptoToken.builtInPresets.prefix(3)))
    try await repo.saveTokens(Array(CryptoToken.builtInPresets.prefix(1)))
    let loaded = try await repo.loadTokens()
    #expect(loaded.count == 1)
  }
}
