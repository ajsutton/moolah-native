// MoolahTests/Support/CountingRateClient.swift
import Foundation
import os

@testable import Moolah

/// Wraps an `ExchangeRateClient` and counts every `fetchRates` call so tests
/// can assert that `ExchangeRateService` only goes to the network when the
/// cached range cannot satisfy the request.
final class CountingRateClient: ExchangeRateClient {
  private let inner: any ExchangeRateClient
  private let count = OSAllocatedUnfairLock<Int>(initialState: 0)

  init(_ inner: any ExchangeRateClient) {
    self.inner = inner
  }

  var fetchCount: Int {
    count.withLock { $0 }
  }

  func fetchRates(base: String, from: Date, to: Date) async throws -> [String: [String: Decimal]] {
    count.withLock { $0 += 1 }
    return try await inner.fetchRates(base: base, from: from, to: to)
  }
}
