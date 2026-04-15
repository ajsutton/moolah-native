// Domain/Repositories/CryptoTokenRepository.swift
import Foundation

protocol CryptoTokenRepository: Sendable {
  func loadRegistrations() async throws -> [CryptoRegistration]
  func saveRegistrations(_ registrations: [CryptoRegistration]) async throws
}
