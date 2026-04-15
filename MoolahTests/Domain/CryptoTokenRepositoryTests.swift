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
    let registrations = try await repo.loadRegistrations()
    #expect(registrations.isEmpty)
  }

  @Test func roundTrip_saveAndLoad() async throws {
    let repo = makeRepository()
    let registrations = Array(CryptoRegistration.builtInPresets.prefix(2))
    try await repo.saveRegistrations(registrations)
    let loaded = try await repo.loadRegistrations()
    #expect(loaded.count == 2)
    #expect(loaded[0].id == registrations[0].id)
    #expect(loaded[1].id == registrations[1].id)
  }

  @Test func saveOverwritesPreviousList() async throws {
    let repo = makeRepository()
    try await repo.saveRegistrations(Array(CryptoRegistration.builtInPresets.prefix(3)))
    try await repo.saveRegistrations(Array(CryptoRegistration.builtInPresets.prefix(1)))
    let loaded = try await repo.loadRegistrations()
    #expect(loaded.count == 1)
  }
}
