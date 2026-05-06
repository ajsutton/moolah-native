// Shared/CryptoImport/AlchemyClient.swift
import Foundation
import OSLog
import os

/// Public protocol so test stubs can replace the live client. Stage 6's
/// `WalletSyncEngine` injects an `AlchemyClient` rather than a concrete
/// struct; v1 ships only `LiveAlchemyClient` plus per-test stubs.
protocol AlchemyClient: Sendable {
  /// Returns transfers in `[fromBlock, latestBlock]` for `walletAddress`,
  /// in two passes: `fromAddress = walletAddress` and
  /// `toAddress = walletAddress`. Categories include `external` and
  /// `erc20` always; `internal` is included only when
  /// `chain.supportsInternalTransfers` is `true`. NFT categories are
  /// always excluded at the request level.
  func getAssetTransfers(
    chain: ChainConfig,
    walletAddress: String,
    fromBlock: UInt64
  ) async throws -> [AlchemyTransfer]

  /// Best-effort token metadata fetch — used for `isSpam` classification
  /// in Stage 5's discovery service. Native tokens are not represented
  /// by a contract address, so callers do not call this for native gas.
  func getTokenMetadata(
    chain: ChainConfig,
    contractAddress: String
  ) async throws -> AlchemyTokenMetadata
}

/// Token metadata returned by Alchemy's `alchemy_getTokenMetadata` JSON-RPC
/// method. All fields are optional because Alchemy returns `null` for
/// unknown tokens. `isSpam` is `false` if the field is absent — the field
/// is only present on chains where Alchemy provides spam classification.
struct AlchemyTokenMetadata: Sendable, Hashable, Codable {
  let symbol: String?
  let name: String?
  let decimals: Int?
  let logo: URL?
  let isSpam: Bool
}

extension AlchemyTokenMetadata {
  /// Custom decoder so a missing `isSpam` field decodes as `false` rather
  /// than failing the decode. Defined in an extension to preserve the
  /// synthesised memberwise initializer on the primary declaration.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let symbol = try container.decodeIfPresent(String.self, forKey: .symbol)
    let name = try container.decodeIfPresent(String.self, forKey: .name)
    let decimals = try container.decodeIfPresent(Int.self, forKey: .decimals)
    let logo = try container.decodeIfPresent(URL.self, forKey: .logo)
    let isSpam = try container.decodeIfPresent(Bool.self, forKey: .isSpam) ?? false
    self.init(symbol: symbol, name: name, decimals: decimals, logo: logo, isSpam: isSpam)
  }
}

/// Live `AlchemyClient` over `URLSession`. Sendable struct — no mutable
/// state; mirrors the shape of `Backends/CoinGecko/CoinGeckoClient.swift`.
///
/// Privacy classifications follow the design table:
/// `chainId` and block numbers → `.public`; wallet addresses and contract
/// addresses → `.private`; the API key is never logged.
struct LiveAlchemyClient: AlchemyClient {
  private let session: URLSession
  private let apiKey: String
  private let rateLimiter: RateLimiter
  private let logger: Logger

  /// - Parameters:
  ///   - session: `URLSession` for HTTP requests. Default is `.shared`;
  ///     tests inject an ephemeral session backed by `URLProtocol`.
  ///   - apiKey: Alchemy API key. Never logged.
  ///   - rateLimiter: Shared `RateLimiter` actor — caller is responsible
  ///     for sizing it to the Alchemy plan in use (25 req/s on free tier).
  init(
    session: URLSession = .shared,
    apiKey: String,
    rateLimiter: RateLimiter
  ) {
    self.session = session
    self.apiKey = apiKey
    self.rateLimiter = rateLimiter
    self.logger = Logger(subsystem: "com.moolah.app", category: "AlchemyClient")
  }

  func getAssetTransfers(
    chain: ChainConfig,
    walletAddress: String,
    fromBlock: UInt64
  ) async throws -> [AlchemyTransfer] {
    let signpostID = OSSignpostID(log: Signposts.cryptoSync)
    os_signpost(
      .begin,
      log: Signposts.cryptoSync,
      name: "alchemy.getAssetTransfers",
      signpostID: signpostID,
      "chain %{public}d",
      chain.chainId)
    defer {
      os_signpost(
        .end,
        log: Signposts.cryptoSync,
        name: "alchemy.getAssetTransfers",
        signpostID: signpostID)
    }
    var transfers: [AlchemyTransfer] = []
    transfers.append(
      contentsOf: try await fetchTransfers(
        chain: chain,
        address: walletAddress,
        isFromAddress: true,
        fromBlock: fromBlock
      )
    )
    transfers.append(
      contentsOf: try await fetchTransfers(
        chain: chain,
        address: walletAddress,
        isFromAddress: false,
        fromBlock: fromBlock
      )
    )
    return transfers
  }

  func getTokenMetadata(
    chain: ChainConfig,
    contractAddress: String
  ) async throws -> AlchemyTokenMetadata {
    try await rateLimiter.acquire()
    let body = JSONRPCRequest<AlchemyParams>(
      method: "alchemy_getTokenMetadata",
      params: .tokenMetadata(contractAddress: contractAddress)
    )
    let request = try buildRequest(chain: chain, body: body)
    logger.debug(
      "Alchemy token metadata: chain \(chain.chainId, privacy: .public) contract \(contractAddress, privacy: .private)"
    )
    let data = try await send(request: request, stage: "getTokenMetadata")
    do {
      let envelope = try JSONDecoder().decode(
        JSONRPCResponse<AlchemyTokenMetadata>.self,
        from: data
      )
      return envelope.result
    } catch {
      logger.error(
        "Alchemy token metadata decode failed for chain \(chain.chainId, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
      throw WalletSyncError.providerMalformedResponse(stage: "getTokenMetadata")
    }
  }

  // MARK: - Internals

  private func fetchTransfers(
    chain: ChainConfig,
    address: String,
    isFromAddress: Bool,
    fromBlock: UInt64
  ) async throws -> [AlchemyTransfer] {
    try await rateLimiter.acquire()

    var categories: [AlchemyTransferCategory] = [.external, .erc20]
    if chain.supportsInternalTransfers {
      categories.append(.internal)
    }
    let body = JSONRPCRequest<AlchemyParams>(
      method: "alchemy_getAssetTransfers",
      params: .assetTransfers(
        AssetTransfersParams(
          fromBlock: "0x" + String(fromBlock, radix: 16),
          toBlock: "latest",
          fromAddress: isFromAddress ? address : nil,
          toAddress: isFromAddress ? nil : address,
          category: categories.map(\.rawValue),
          withMetadata: true,
          excludeZeroValue: true
        )
      )
    )
    let request = try buildRequest(chain: chain, body: body)
    logger.debug(
      """
      Alchemy getAssetTransfers: chain \(chain.chainId, privacy: .public) \
      direction \(isFromAddress ? "from" : "to", privacy: .public) \
      address \(address, privacy: .private) \
      fromBlock \(fromBlock, privacy: .public)
      """
    )

    let data = try await send(request: request, stage: "getAssetTransfers")
    do {
      let envelope = try JSONDecoder().decode(AlchemyTransferEnvelope.self, from: data)
      return envelope.result.transfers
    } catch {
      logger.error(
        "Alchemy getAssetTransfers decode failed for chain \(chain.chainId, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
      throw WalletSyncError.providerMalformedResponse(stage: "getAssetTransfers")
    }
  }

  private func send(request: URLRequest, stage: String) async throws -> Data {
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch let urlError as URLError where urlError.code == .cancelled {
      throw CancellationError()
    } catch {
      logger.error(
        "Alchemy \(stage, privacy: .public) network failure: \(error.localizedDescription, privacy: .public)"
      )
      throw WalletSyncError.network(underlyingDescription: error.localizedDescription)
    }
    try validate(response: response, stage: stage)
    return data
  }

  private func buildRequest<Params: Encodable>(
    chain: ChainConfig,
    body: JSONRPCRequest<Params>
  ) throws -> URLRequest {
    let urlString = "https://\(chain.alchemyNetworkSlug).g.alchemy.com/v2/\(apiKey)"
    guard let url = URL(string: urlString) else {
      throw WalletSyncError.network(
        underlyingDescription: "Malformed Alchemy URL for chain \(chain.chainId)"
      )
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    do {
      request.httpBody = try JSONEncoder().encode(body)
    } catch {
      throw WalletSyncError.providerMalformedResponse(stage: "encodeRequestBody")
    }
    return request
  }

  private func validate(response: URLResponse, stage: String) throws {
    guard let http = response as? HTTPURLResponse else {
      logger.error(
        "Alchemy \(stage, privacy: .public): non-HTTP response"
      )
      throw WalletSyncError.network(underlyingDescription: "No HTTP response")
    }
    switch http.statusCode {
    case 200...299:
      return
    case 401, 403:
      logger.error(
        "Alchemy \(stage, privacy: .public): API key rejected (HTTP \(http.statusCode, privacy: .public))"
      )
      throw WalletSyncError.invalidApiKey
    case 429:
      let retryAfter = parseRetryAfter(http: http)
      logger.notice(
        "Alchemy \(stage, privacy: .public): rate limited (HTTP 429)"
      )
      throw WalletSyncError.rateLimited(retryAfter: retryAfter)
    default:
      logger.error(
        "Alchemy \(stage, privacy: .public): HTTP \(http.statusCode, privacy: .public)"
      )
      throw WalletSyncError.network(
        underlyingDescription: "HTTP \(http.statusCode)"
      )
    }
  }

  /// Parses `Retry-After` per RFC 7231: either a non-negative integer
  /// seconds value or an HTTP-date. Returns `nil` when the header is
  /// absent or unparseable.
  private func parseRetryAfter(http: HTTPURLResponse) -> Date? {
    guard let header = http.value(forHTTPHeaderField: "Retry-After") else {
      return nil
    }
    let trimmed = header.trimmingCharacters(in: .whitespaces)
    if let seconds = TimeInterval(trimmed) {
      return Date().addingTimeInterval(seconds)
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return formatter.date(from: trimmed)
  }
}

// MARK: - JSON-RPC envelope

/// Outer JSON-RPC 2.0 request envelope. `id` is fixed at 1 — Alchemy
/// echoes it back, but our requests are single-shot so we don't correlate.
private struct JSONRPCRequest<Params: Encodable>: Encodable {
  let jsonrpc: String
  let id: Int
  let method: String
  let params: Params

  init(method: String, params: Params) {
    self.jsonrpc = "2.0"
    self.id = 1
    self.method = method
    self.params = params
  }
}

/// Outer JSON-RPC 2.0 response envelope, generic over the result body.
private struct JSONRPCResponse<Result: Decodable>: Decodable {
  let result: Result
}

/// Discriminated `params` payload — covers the two JSON-RPC methods this
/// client makes today. Each case encodes as the JSON-RPC convention of a
/// one-element array around the parameter object (or address string).
private enum AlchemyParams: Encodable {
  case assetTransfers(AssetTransfersParams)
  case tokenMetadata(contractAddress: String)

  func encode(to encoder: Encoder) throws {
    var container = encoder.unkeyedContainer()
    switch self {
    case .assetTransfers(let params):
      try container.encode(params)
    case .tokenMetadata(let address):
      try container.encode(address)
    }
  }
}

/// Body for the `params[0]` object of `alchemy_getAssetTransfers`.
private struct AssetTransfersParams: Encodable {
  let fromBlock: String
  let toBlock: String
  let fromAddress: String?
  let toAddress: String?
  let category: [String]
  let withMetadata: Bool
  let excludeZeroValue: Bool
}

/// Decodes the `result` object of `alchemy_getAssetTransfers`. The
/// outer envelope wraps this in `JSONRPCResponse<AlchemyTransferResult>`.
private struct AlchemyTransferEnvelope: Decodable {
  let result: AlchemyTransferResult
}

private struct AlchemyTransferResult: Decodable {
  let transfers: [AlchemyTransfer]
}
