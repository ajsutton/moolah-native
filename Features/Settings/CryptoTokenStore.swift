// Features/Settings/CryptoTokenStore.swift
import Foundation

@MainActor @Observable
final class CryptoTokenStore {
  // Legacy accessor retained for backward compatibility with views
  private(set) var tokens: [CryptoToken] = []

  // New Instrument-based accessors
  private(set) var cryptoInstruments: [Instrument] = []
  private(set) var providerMappings: [String: CryptoProviderMapping] = [:]

  private(set) var isLoading = false
  private(set) var isResolving = false

  // Legacy accessor retained for backward compatibility with views
  var resolvedToken: CryptoToken?

  // New Instrument-based resolved state
  var resolvedInstrument: Instrument?
  var resolvedMapping: CryptoProviderMapping?

  private(set) var error: String?

  private let cryptoPriceService: CryptoPriceService

  private let apiKeyStore = KeychainStore(
    service: "com.moolah.api-keys", account: "coingecko", synchronizable: true
  )

  init(cryptoPriceService: CryptoPriceService) {
    self.cryptoPriceService = cryptoPriceService
  }

  func loadTokens() async {
    isLoading = true
    defer { isLoading = false }
    let loadedTokens = await cryptoPriceService.registeredTokens()
    tokens = loadedTokens
    cryptoInstruments = loadedTokens.map { CryptoProviderMapping.instrument(from: $0) }
    providerMappings = Dictionary(
      loadedTokens.map {
        (CryptoProviderMapping.from($0).instrumentId, CryptoProviderMapping.from($0))
      },
      uniquingKeysWith: { _, last in last }
    )
  }

  func removeToken(_ token: CryptoToken) async {
    do {
      try await cryptoPriceService.removeToken(token)
      tokens.removeAll { $0.id == token.id }
      cryptoInstruments.removeAll { $0.id == token.id }
      providerMappings.removeValue(forKey: token.id)
    } catch {
      self.error = error.localizedDescription
    }
  }

  func removeInstrument(_ instrument: Instrument) async {
    guard let mapping = providerMappings[instrument.id] else { return }
    let token = CryptoPriceService.bridgeToToken(instrument: instrument, mapping: mapping)
    do {
      try await cryptoPriceService.removeToken(token)
      tokens.removeAll { $0.id == instrument.id }
      cryptoInstruments.removeAll { $0.id == instrument.id }
      providerMappings.removeValue(forKey: instrument.id)
    } catch {
      self.error = error.localizedDescription
    }
  }

  func resolveToken(
    chainId: Int, contractAddress: String?, symbol: String?, isNative: Bool
  ) async {
    isResolving = true
    resolvedToken = nil
    resolvedInstrument = nil
    resolvedMapping = nil
    error = nil
    defer { isResolving = false }

    do {
      let token = try await cryptoPriceService.resolveToken(
        chainId: chainId,
        contractAddress: contractAddress,
        symbol: symbol,
        isNative: isNative
      )
      resolvedToken = token
      resolvedInstrument = CryptoProviderMapping.instrument(from: token)
      resolvedMapping = CryptoProviderMapping.from(token)
    } catch {
      self.error = "Resolution failed: \(error.localizedDescription)"
    }
  }

  func confirmRegistration() async {
    guard let token = resolvedToken else { return }
    do {
      try await cryptoPriceService.registerToken(token)
      tokens.append(token)
      if let instrument = resolvedInstrument {
        cryptoInstruments.append(instrument)
      }
      if let mapping = resolvedMapping {
        providerMappings[mapping.instrumentId] = mapping
      }
      resolvedToken = nil
      resolvedInstrument = nil
      resolvedMapping = nil
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
