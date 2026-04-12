// MoolahTests/Support/InMemoryTokenRepository.swift
import Foundation

@testable import Moolah

final class InMemoryTokenRepository: CryptoTokenRepository, @unchecked Sendable {
  private var tokens: [CryptoToken] = []

  func loadTokens() async throws -> [CryptoToken] {
    tokens
  }

  func saveTokens(_ tokens: [CryptoToken]) async throws {
    self.tokens = tokens
  }
}
