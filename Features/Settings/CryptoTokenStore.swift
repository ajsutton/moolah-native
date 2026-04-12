// Features/Settings/CryptoTokenStore.swift
import Foundation

@MainActor @Observable
final class CryptoTokenStore {
  private(set) var registrations: [CryptoRegistration] = []
  private(set) var instruments: [Instrument] = []
  private(set) var providerMappings: [String: CryptoProviderMapping] = [:]

  private(set) var isLoading = false
  private(set) var isResolving = false

  var resolvedRegistration: CryptoRegistration?

  private(set) var error: String?

  private let cryptoPriceService: CryptoPriceService

  private let apiKeyStore = KeychainStore(
    service: "com.moolah.api-keys", account: "coingecko", synchronizable: true
  )

  init(cryptoPriceService: CryptoPriceService) {
    self.cryptoPriceService = cryptoPriceService
  }

  func loadRegistrations() async {
    isLoading = true
    defer { isLoading = false }
    let loaded = await cryptoPriceService.registeredItems()
    registrations = loaded
    instruments = loaded.map(\.instrument)
    providerMappings = Dictionary(
      loaded.map { ($0.mapping.instrumentId, $0.mapping) },
      uniquingKeysWith: { _, last in last }
    )
  }

  func removeRegistration(_ registration: CryptoRegistration) async {
    do {
      try await cryptoPriceService.remove(registration)
      registrations.removeAll { $0.id == registration.id }
      instruments.removeAll { $0.id == registration.id }
      providerMappings.removeValue(forKey: registration.id)
    } catch {
      self.error = error.localizedDescription
    }
  }

  func removeInstrument(_ instrument: Instrument) async {
    guard let registration = registrations.first(where: { $0.instrument.id == instrument.id })
    else { return }
    await removeRegistration(registration)
  }

  func resolveToken(
    chainId: Int, contractAddress: String?, symbol: String?, isNative: Bool
  ) async {
    isResolving = true
    resolvedRegistration = nil
    error = nil
    defer { isResolving = false }

    do {
      resolvedRegistration = try await cryptoPriceService.resolveRegistration(
        chainId: chainId,
        contractAddress: contractAddress,
        symbol: symbol,
        isNative: isNative
      )
    } catch {
      self.error = "Resolution failed: \(error.localizedDescription)"
    }
  }

  func confirmRegistration() async {
    guard let registration = resolvedRegistration else { return }
    do {
      try await cryptoPriceService.register(registration)
      registrations.append(registration)
      instruments.append(registration.instrument)
      providerMappings[registration.mapping.instrumentId] = registration.mapping
      resolvedRegistration = nil
    } catch {
      self.error = error.localizedDescription
    }
  }

  // MARK: - API Key

  var hasApiKey: Bool {
    (try? apiKeyStore.restoreString()) != nil
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
