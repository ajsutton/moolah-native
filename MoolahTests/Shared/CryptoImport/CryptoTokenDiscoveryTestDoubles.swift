// MoolahTests/Shared/CryptoImport/CryptoTokenDiscoveryTestDoubles.swift
import Foundation

@testable import Moolah

/// Namespace matching this file's name so SwiftLint's `file_name` rule
/// stays satisfied alongside the loose top-level helpers and the two
/// counting stubs declared below. Mirrors the `AlchemyTestSupport`
/// pattern in the sibling Alchemy test files.
enum CryptoTokenDiscoveryTestDoubles {}

/// Counting + scriptable resolver. Records every call and returns the
/// scripted response for the matching key. The default response is a
/// successful resolution producing a mapping with one provider id.
///
/// `@unchecked Sendable`: scripted responses and call counts live behind
/// an `NSLock`, mirroring the lock-protected stubs in `AlchemyTestSupport`
/// and the `RateLimiterTests` test clock. The lock-bracket pattern is
/// the project convention for non-actor concurrent test stubs.
final class CountingRegistrationResolver: CryptoRegistrationResolver, @unchecked Sendable {
  enum Response: Sendable {
    case success(coingecko: String?, cryptocompare: String?, binance: String?)
    case failure(any Error)
  }

  struct Key: Hashable, Sendable {
    let chainId: Int
    let contractAddress: String?
  }

  private let lock = NSLock()
  private var responses: [Key: Response] = [:]
  private var callCounts: [Key: Int] = [:]
  private var defaultResponse: Response = .success(
    coingecko: "default-id", cryptocompare: nil, binance: nil)

  func setDefault(_ response: Response) {
    lock.withLock { self.defaultResponse = response }
  }

  func script(_ key: Key, _ response: Response) {
    lock.withLock { responses[key] = response }
  }

  func callCount(for key: Key) -> Int {
    lock.withLock { callCounts[key] ?? 0 }
  }

  func resolveRegistration(
    chainId: Int,
    contractAddress: String?,
    symbol: String?,
    isNative: Bool
  ) async throws -> CryptoRegistration {
    let key = Key(chainId: chainId, contractAddress: contractAddress?.lowercased())
    let response: Response = lock.withLock {
      callCounts[key, default: 0] += 1
      return responses[key] ?? defaultResponse
    }

    switch response {
    case let .failure(error):
      throw error
    case let .success(coingecko, cryptocompare, binance):
      let resolvedSymbol = symbol ?? "TKN"
      let instrument = Instrument.crypto(
        chainId: chainId,
        contractAddress: isNative ? nil : contractAddress,
        symbol: resolvedSymbol,
        name: resolvedSymbol,
        decimals: 18)
      let mapping = CryptoProviderMapping(
        instrumentId: instrument.id,
        coingeckoId: coingecko,
        cryptocompareSymbol: cryptocompare,
        binanceSymbol: binance)
      return CryptoRegistration(instrument: instrument, mapping: mapping)
    }
  }
}

/// Counting + scriptable Alchemy stub. Only `getTokenMetadata` is
/// exercised by Stage 5; `getAssetTransfers` is unused here and traps if
/// called so an accidental call surfaces in tests.
final class CountingAlchemyClientStub: AlchemyClient, @unchecked Sendable {
  struct Key: Hashable, Sendable {
    let chainId: Int
    let contractAddress: String
  }

  enum Response: Sendable {
    case metadata(AlchemyTokenMetadata)
    case failure(any Error)
  }

  struct UnexpectedTransfersCall: Error {}
  /// Thrown when an unrelated test path triggers a receipt fetch. The
  /// discovery service never calls `getTransactionReceipt`, so any
  /// invocation here is a wiring bug worth surfacing.
  struct UnexpectedReceiptCall: Error {}

  private let lock = NSLock()
  private var responses: [Key: Response] = [:]
  private var callCounts: [Key: Int] = [:]
  private var defaultIsSpam: Bool = false
  private var totalGetTokenMetadataCalls: Int = 0

  /// Total number of `getTokenMetadata` calls across all keys.
  var tokenMetadataCallCount: Int {
    lock.withLock { totalGetTokenMetadataCalls }
  }

  func setDefaultSpam(_ isSpam: Bool) {
    lock.withLock { self.defaultIsSpam = isSpam }
  }

  func script(_ key: Key, _ response: Response) {
    lock.withLock { responses[key] = response }
  }

  func callCount(for key: Key) -> Int {
    lock.withLock { callCounts[key] ?? 0 }
  }

  func getAssetTransfers(
    chain: ChainConfig,
    walletAddress: String,
    fromBlock: UInt64
  ) async throws -> [AlchemyTransfer] {
    throw UnexpectedTransfersCall()
  }

  func getTokenMetadata(
    chain: ChainConfig,
    contractAddress: String
  ) async throws -> AlchemyTokenMetadata {
    let key = Key(chainId: chain.chainId, contractAddress: contractAddress.lowercased())
    let (response, fallbackSpam): (Response?, Bool) = lock.withLock {
      callCounts[key, default: 0] += 1
      totalGetTokenMetadataCalls += 1
      return (responses[key], defaultIsSpam)
    }

    switch response {
    case let .failure(error):
      throw error
    case let .metadata(metadata):
      return metadata
    case .none:
      return AlchemyTokenMetadata(
        symbol: nil, name: nil, decimals: nil, logo: nil, isSpam: fallbackSpam)
    }
  }

  func getTransactionReceipt(
    chain: ChainConfig,
    hash: String
  ) async throws -> AlchemyTransactionReceipt {
    throw UnexpectedReceiptCall()
  }
}

/// Bundle returned by `makeDiscoverySubject()` — a struct rather than a
/// tuple so SwiftLint's `large_tuple` rule (max 2 members) stays clean
/// and call sites can address fields by name.
struct CryptoTokenDiscoverySubject: Sendable {
  let service: CryptoTokenDiscoveryService
  let registry: StubInstrumentRegistry
  let resolver: CountingRegistrationResolver
  let alchemy: CountingAlchemyClientStub
}

/// Builds a `CryptoTokenDiscoveryService` wired against the in-memory
/// `StubInstrumentRegistry` plus the counting test doubles. Tests script
/// resolver / Alchemy responses on the returned bundle's fields.
func makeDiscoverySubject(
  seededRegistrations: [CryptoRegistration] = []
) -> CryptoTokenDiscoverySubject {
  let registry = StubInstrumentRegistry(cryptoRegistrations: seededRegistrations)
  let resolver = CountingRegistrationResolver()
  let alchemy = CountingAlchemyClientStub()
  let service = CryptoTokenDiscoveryService(
    registry: registry, resolver: resolver, alchemy: alchemy)
  return CryptoTokenDiscoverySubject(
    service: service, registry: registry, resolver: resolver, alchemy: alchemy)
}
