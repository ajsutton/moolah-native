// MoolahTests/Support/ExchangeSyncEngineTestSupport.swift
import Foundation

@testable import Moolah

/// Builds a `ExchangeSyncEngine` wired against the provided registry and an
/// optional `CountingRegistrationResolver`. When `regResolver` is `nil` a
/// default resolver scripted with a `.success` response is created
/// automatically. The Alchemy stub and discovery service are created fresh
/// each call so tests that need to inspect them should pass an explicit
/// `regResolver` or construct the engine manually.
///
/// `existingLegInstrumentIds` always returns `[]` — suitable for resolution
/// tests that do not need to exercise the used-instrument preference ranking.
func makeExchangeSyncEngine(
  registry: StubInstrumentRegistry = StubInstrumentRegistry(),
  regResolver: CountingRegistrationResolver? = nil
) -> ExchangeSyncEngine {
  let resolverToUse: CountingRegistrationResolver
  if let regResolver {
    resolverToUse = regResolver
  } else {
    let defaultResolver = CountingRegistrationResolver()
    defaultResolver.setDefault(.success(coingecko: "id", cryptocompare: nil, binance: nil))
    resolverToUse = defaultResolver
  }
  let discovery = CryptoTokenDiscoveryService(
    registry: registry, resolver: resolverToUse, alchemy: CountingAlchemyClientStub())
  return ExchangeSyncEngine(
    resolver: ExchangeInstrumentResolver(
      registry: registry, fiatInstrument: .AUD,
      existingLegInstrumentIds: { [] }),
    discovery: discovery)
}
