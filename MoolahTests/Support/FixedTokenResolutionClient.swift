// MoolahTests/Support/FixedTokenResolutionClient.swift
import Foundation

@testable import Moolah

struct FixedTokenResolutionClient: TokenResolutionClient, Sendable {
  let result: TokenResolutionResult
  let shouldFail: Bool

  init(result: TokenResolutionResult = TokenResolutionResult(), shouldFail: Bool = false) {
    self.result = result
    self.shouldFail = shouldFail
  }

  func resolve(
    chainId: Int, contractAddress: String?, symbol: String?, isNative: Bool
  ) async throws -> TokenResolutionResult {
    if shouldFail { throw URLError(.notConnectedToInternet) }
    return result
  }
}
