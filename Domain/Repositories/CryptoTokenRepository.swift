// Domain/Repositories/CryptoTokenRepository.swift
import Foundation

protocol CryptoTokenRepository: Sendable {
  func loadTokens() async throws -> [CryptoToken]
  func saveTokens(_ tokens: [CryptoToken]) async throws
}
