// MoolahTests/Support/InMemoryTokenRepository.swift
import Foundation

@testable import Moolah

final class InMemoryTokenRepository: CryptoTokenRepository, @unchecked Sendable {
  private var registrations: [CryptoRegistration] = []

  func loadRegistrations() async throws -> [CryptoRegistration] {
    registrations
  }

  func saveRegistrations(_ registrations: [CryptoRegistration]) async throws {
    self.registrations = registrations
  }
}
