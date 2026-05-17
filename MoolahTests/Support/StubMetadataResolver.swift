// MoolahTests/Support/StubMetadataResolver.swift
import Foundation

@testable import Moolah

/// In-memory stub of `ExchangeAssetMetadataResolving` for engine and source
/// unit tests. Returns a fixed dictionary mapping — `nil` for any symbol not
/// in the map, or a scripted `ExchangeAssetMetadata` otherwise. An optional
/// `onCall` hook lets tests assert which symbols were (or were not) looked up
/// without needing to inspect returned values.
///
/// `@unchecked Sendable`: `map` and `onCall` are both immutable after init
/// (all `let`); `onCall` itself is `@Sendable`. The class is `final` with
/// no mutable state so the `@unchecked` annotation is safe — there is nothing
/// to guard with a lock.
final class StubMetadataResolver: ExchangeAssetMetadataResolving, @unchecked Sendable {
  let map: [String: ExchangeAssetMetadata?]
  let onCall: @Sendable (String) -> Void

  init(
    _ map: [String: ExchangeAssetMetadata?],
    onCall: @escaping @Sendable (String) -> Void = { _ in }
  ) {
    self.map = map
    self.onCall = onCall
  }

  func assetMetadata(forSymbol symbol: String) async throws -> ExchangeAssetMetadata? {
    onCall(symbol)
    guard let hit = map[symbol] else { return nil }
    return hit
  }
}
