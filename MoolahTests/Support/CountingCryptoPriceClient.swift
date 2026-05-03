// MoolahTests/Support/CountingCryptoPriceClient.swift
import Foundation
import os

@testable import Moolah

/// Wraps a `CryptoPriceClient` and counts every `dailyPrices(for:in:)`
/// call so tests can assert that `CryptoPriceService` only goes to the
/// network when the cached range cannot satisfy the request. Mirrors
/// the role `CountingRateClient` plays for `ExchangeRateService`.
final class CountingCryptoPriceClient: CryptoPriceClient {
  private let inner: any CryptoPriceClient
  private let count = OSAllocatedUnfairLock<Int>(initialState: 0)

  init(_ inner: any CryptoPriceClient) {
    self.inner = inner
  }

  var fetchCount: Int {
    count.withLock { $0 }
  }

  func dailyPrice(for mapping: CryptoProviderMapping, on date: Date) async throws -> Decimal {
    count.withLock { $0 += 1 }
    return try await inner.dailyPrice(for: mapping, on: date)
  }

  func dailyPrices(
    for mapping: CryptoProviderMapping, in range: ClosedRange<Date>
  ) async throws -> [String: Decimal] {
    count.withLock { $0 += 1 }
    return try await inner.dailyPrices(for: mapping, in: range)
  }

  func currentPrices(for mappings: [CryptoProviderMapping]) async throws -> [String: Decimal] {
    count.withLock { $0 += 1 }
    return try await inner.currentPrices(for: mappings)
  }
}
