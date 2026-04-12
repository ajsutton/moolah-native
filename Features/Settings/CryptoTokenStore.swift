// Features/Settings/CryptoTokenStore.swift
import Foundation

@MainActor @Observable
final class CryptoTokenStore {
  private(set) var tokens: [CryptoToken] = []
  private(set) var isLoading = false
  private(set) var isResolving = false
  var resolvedToken: CryptoToken?
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
    tokens = await cryptoPriceService.registeredTokens()
  }

  func removeToken(_ token: CryptoToken) async {
    do {
      try await cryptoPriceService.removeToken(token)
      tokens.removeAll { $0.id == token.id }
    } catch {
      self.error = error.localizedDescription
    }
  }

  func resolveToken(
    chainId: Int, contractAddress: String?, symbol: String?, isNative: Bool
  ) async {
    isResolving = true
    resolvedToken = nil
    error = nil
    defer { isResolving = false }

    do {
      resolvedToken = try await cryptoPriceService.resolveToken(
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
    guard let token = resolvedToken else { return }
    do {
      try await cryptoPriceService.registerToken(token)
      tokens.append(token)
      resolvedToken = nil
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
