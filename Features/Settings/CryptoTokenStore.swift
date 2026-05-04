// Features/Settings/CryptoTokenStore.swift
import Foundation
import OSLog

@MainActor
@Observable
final class CryptoTokenStore {
  private(set) var registrations: [CryptoRegistration] = []
  private(set) var instruments: [Instrument] = []
  private(set) var providerMappings: [String: CryptoProviderMapping] = [:]

  private(set) var isLoading = false

  private(set) var error: String?

  private let registry: any InstrumentRegistryRepository
  private let cryptoPriceService: CryptoPriceService
  private let logger = Logger(
    subsystem: "com.moolah.app", category: "CryptoTokenStore")

  private let apiKeyStore = KeychainStore(
    service: "com.moolah.api-keys", account: "coingecko", synchronizable: true
  )

  init(
    registry: any InstrumentRegistryRepository,
    cryptoPriceService: CryptoPriceService
  ) {
    self.registry = registry
    self.cryptoPriceService = cryptoPriceService
  }

  func loadRegistrations() async {
    isLoading = true
    defer { isLoading = false }
    do {
      let loaded = try await registry.allCryptoRegistrations()
      registrations = loaded
      instruments = loaded.map(\.instrument)
      providerMappings = Dictionary(
        loaded.map { ($0.mapping.instrumentId, $0.mapping) },
        uniquingKeysWith: { _, last in last }
      )
      error = nil
    } catch {
      logger.error(
        "Failed to load crypto registrations: \(error, privacy: .public)")
      self.error = error.localizedDescription
    }
  }

  func removeRegistration(_ registration: CryptoRegistration) async {
    do {
      try await registry.remove(id: registration.id)
      await cryptoPriceService.purgeCache(instrumentId: registration.id)
      registrations.removeAll { $0.id == registration.id }
      instruments.removeAll { $0.id == registration.id }
      providerMappings.removeValue(forKey: registration.id)
    } catch {
      logger.error("Failed to remove registration: \(error, privacy: .public)")
      self.error = error.localizedDescription
    }
  }

  func removeInstrument(_ instrument: Instrument) async {
    guard let registration = registrations.first(where: { $0.instrument.id == instrument.id })
    else { return }
    await removeRegistration(registration)
  }

  // MARK: - API Key

  var hasApiKey: Bool {
    do {
      return try apiKeyStore.restoreString() != nil
    } catch {
      logger.error("keychain read failed: \(error.localizedDescription)")
      return false
    }
  }

  func saveApiKey(_ key: String) {
    do {
      try apiKeyStore.saveString(key)
    } catch {
      self.error = "Failed to save API key: \(error.localizedDescription)"
    }
  }

  func clearApiKey() {
    apiKeyStore.clear()
  }
}
