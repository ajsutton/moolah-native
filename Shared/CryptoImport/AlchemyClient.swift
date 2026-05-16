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
  /// `chain.supportsInternalTransfers` is `true` (currently no supported
  /// chain — Blockscout owns internal ETH on all of them). NFT categories
  /// are always excluded at the request level.
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

  /// Fetches the on-chain receipt for `hash` so the wallet sync
  /// pipeline can compute the gas-leg quantity (`gasUsed *
  /// effectiveGasPrice`). Alchemy's `alchemy_getAssetTransfers` doesn't
  /// include gas-cost data per transfer, so callers fetch one receipt
  /// per unique outbound `txHash`.
  ///
  /// Throws `WalletSyncError.providerMalformedResponse(stage:
  /// "getTransactionReceipt")` when the JSON-RPC `result` is `null`
  /// (rare — only when the hash isn't on chain yet, or the node has
  /// pruned it) or when the response payload can't be decoded.
  func getTransactionReceipt(
    chain: ChainConfig,
    hash: String
  ) async throws -> AlchemyTransactionReceipt
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

/// The fixed inputs for one direction's paginated transfer fetch.
/// Bundled into a value so the page loop and the per-page round-trip
/// share one parameter instead of threading the same five arguments.
private struct AlchemyTransferQuery: Sendable {
  let chain: ChainConfig
  let address: String
  let isFromAddress: Bool
  let fromBlock: UInt64
  let apiKey: String
}

/// Live `AlchemyClient` over `URLSession`. Sendable struct — no mutable
/// state; mirrors the shape of `Backends/CoinGecko/CoinGeckoClient.swift`.
///
/// Privacy classifications follow the design table:
/// `chainId` and block numbers → `.public`; wallet addresses and contract
/// addresses → `.private`; the API key is never logged.
struct LiveAlchemyClient: AlchemyClient, Sendable {
  private let session: URLSession
  /// Closure that yields the current Alchemy API key, or `nil` when the
  /// keychain has none. Resolved per-request inside each public method
  /// so a key added in settings *after* the client was constructed is
  /// visible on the next call, and so the client never retains the key
  /// in an instance-level field. The resolved key only lives in the
  /// local stack frame of the in-flight request.
  private let apiKeyProvider: @Sendable () -> String?
  private let rateLimiter: RateLimiter
  private let logger: Logger

  /// - Parameters:
  ///   - session: `URLSession` for HTTP requests. Default is `.shared`;
  ///     tests inject an ephemeral session backed by `URLProtocol`.
  ///   - apiKeyProvider: Closure invoked at the start of every network
  ///     method. Reads the keychain on each call so a freshly-added key
  ///     is visible without rebuilding the client; never caches the
  ///     value on the struct. Never logged.
  ///   - rateLimiter: Shared `RateLimiter` actor — caller is responsible
  ///     for sizing it to the Alchemy plan in use (25 req/s on free tier).
  init(
    session: URLSession = .shared,
    apiKeyProvider: @escaping @Sendable () -> String?,
    rateLimiter: RateLimiter
  ) {
    self.session = session
    self.apiKeyProvider = apiKeyProvider
    self.rateLimiter = rateLimiter
    self.logger = Logger(subsystem: "com.moolah.app", category: "AlchemyClient")
  }

  func getAssetTransfers(
    chain: ChainConfig,
    walletAddress: String,
    fromBlock: UInt64
  ) async throws -> [AlchemyTransfer] {
    let apiKey = try resolveApiKey()
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
    for isFromAddress in [true, false] {
      transfers.append(
        contentsOf: try await fetchTransfers(
          AlchemyTransferQuery(
            chain: chain,
            address: walletAddress,
            isFromAddress: isFromAddress,
            fromBlock: fromBlock,
            apiKey: apiKey)))
    }
    return transfers
  }

  func getTokenMetadata(
    chain: ChainConfig,
    contractAddress: String
  ) async throws -> AlchemyTokenMetadata {
    let apiKey = try resolveApiKey()
    try await rateLimiter.acquire()
    let body = AlchemyJSONRPCRequest<AlchemyJSONRPCParams>(
      method: "alchemy_getTokenMetadata",
      params: .tokenMetadata(contractAddress: contractAddress)
    )
    let request = try buildRequest(chain: chain, body: body, apiKey: apiKey)
    logger.debug(
      "Alchemy token metadata: chain \(chain.chainId, privacy: .public) contract \(contractAddress, privacy: .private)"
    )
    let data = try await send(request: request, stage: "getTokenMetadata")
    do {
      let envelope = try JSONDecoder().decode(
        AlchemyJSONRPCResponse<AlchemyTokenMetadata>.self,
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

  func getTransactionReceipt(
    chain: ChainConfig,
    hash: String
  ) async throws -> AlchemyTransactionReceipt {
    let apiKey = try resolveApiKey()
    let signpostID = OSSignpostID(log: Signposts.cryptoSync)
    os_signpost(
      .begin,
      log: Signposts.cryptoSync,
      name: "alchemy.getTransactionReceipt",
      signpostID: signpostID,
      "chain %{public}d",
      chain.chainId)
    defer {
      os_signpost(
        .end,
        log: Signposts.cryptoSync,
        name: "alchemy.getTransactionReceipt",
        signpostID: signpostID)
    }
    try await rateLimiter.acquire()
    let body = AlchemyJSONRPCRequest<AlchemyJSONRPCParams>(
      method: "eth_getTransactionReceipt",
      params: .transactionReceipt(hash: hash)
    )
    let request = try buildRequest(chain: chain, body: body, apiKey: apiKey)
    // Hash is `.private` in logs — pairing a tx hash with the device
    // identifies wallet activity even though the chain itself is public.
    logger.debug(
      "Alchemy getTransactionReceipt: chain \(chain.chainId, privacy: .public) hash \(hash, privacy: .private)"
    )
    let data = try await send(request: request, stage: "getTransactionReceipt")
    do {
      let envelope = try JSONDecoder().decode(
        AlchemyJSONRPCNullableResponse<AlchemyTransactionReceiptPayload>.self,
        from: data
      )
      guard let payload = envelope.result else {
        // `result: null` — happens when the hash isn't on chain (yet) or
        // the node has pruned it. Surface as a malformed-response error
        // so the orchestrator's per-account containment can decide.
        logger.notice(
          "Alchemy getTransactionReceipt returned null result for chain \(chain.chainId, privacy: .public) hash \(hash, privacy: .private)"
        )
        throw WalletSyncError.providerMalformedResponse(stage: "getTransactionReceipt")
      }
      return try payload.toReceipt(hash: hash)
    } catch let error as WalletSyncError {
      throw error
    } catch {
      logger.error(
        "Alchemy getTransactionReceipt decode failed for chain \(chain.chainId, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
      throw WalletSyncError.providerMalformedResponse(stage: "getTransactionReceipt")
    }
  }

  // MARK: - Internals

  /// Resolves the current API key from the closure provider and rejects
  /// missing / empty values with `.missingApiKey`. Called at the top of
  /// every public method; the returned string is held only on the local
  /// stack frame and passed down to `fetchTransfers` / `buildRequest`.
  /// The client never stores the resolved value on `self`.
  ///
  /// The wiring at `ProfileSession.makeCryptoSyncWiring` reads the
  /// keychain on each call (rather than at construction) so a key added
  /// in settings *after* the client was built is visible on the next
  /// request. Without this freshness guarantee the user sees Sync now
  /// 401 with a stale empty-string key even after configuring a valid
  /// one.
  private func resolveApiKey() throws -> String {
    let key = apiKeyProvider() ?? ""
    guard !key.isEmpty else { throw WalletSyncError.missingApiKey }
    return key
  }

  /// Fetches every transfer for one direction. Alchemy caps
  /// `alchemy_getAssetTransfers` at `maxCount` (1000) transfers per
  /// response, oldest-block-first, and returns a `pageKey` when more
  /// remain. This follows the cursor until it is absent — otherwise a
  /// wallet with heavy (often spam-airdrop) history truncates at the
  /// oldest 1000 per direction and the balance is wrong.
  private func fetchTransfers(
    _ query: AlchemyTransferQuery
  ) async throws -> [AlchemyTransfer] {
    var collected: [AlchemyTransfer] = []
    var pageKey: String?
    // Guards against a misbehaving provider that returns a `pageKey`
    // already used: re-requesting it would loop forever. Stop before
    // re-fetching a continuation cursor that has already been requested.
    var requestedPageKeys: Set<String> = []
    while true {
      if let pageKey, !requestedPageKeys.insert(pageKey).inserted {
        break
      }
      let result = try await fetchTransferPage(query, pageKey: pageKey)
      collected.append(contentsOf: result.transfers)
      pageKey = result.pageKey
      if pageKey == nil { break }
    }
    return collected
  }

  /// One rate-limited `alchemy_getAssetTransfers` round-trip for a
  /// single direction and page. `pageKey` is `nil` for the first page;
  /// the caller threads back `result.pageKey` for subsequent pages.
  private func fetchTransferPage(
    _ query: AlchemyTransferQuery,
    pageKey: String?
  ) async throws -> AlchemyTransferResult {
    let chain = query.chain
    var categories: [AlchemyTransferCategory] = [.external, .erc20]
    if chain.supportsInternalTransfers {
      categories.append(.internal)
    }
    try await rateLimiter.acquire()
    let body = AlchemyJSONRPCRequest<AlchemyJSONRPCParams>(
      method: "alchemy_getAssetTransfers",
      params: .assetTransfers(
        AlchemyAssetTransfersParams(
          fromBlock: "0x" + String(query.fromBlock, radix: 16),
          toBlock: "latest",
          fromAddress: query.isFromAddress ? query.address : nil,
          toAddress: query.isFromAddress ? nil : query.address,
          category: categories.map(\.rawValue),
          withMetadata: true,
          excludeZeroValue: true,
          pageKey: pageKey
        )
      )
    )
    let request = try buildRequest(chain: chain, body: body, apiKey: query.apiKey)
    logger.debug(
      """
      Alchemy getAssetTransfers: chain \(chain.chainId, privacy: .public) \
      direction \(query.isFromAddress ? "from" : "to", privacy: .public) \
      address \(query.address, privacy: .private) \
      fromBlock \(query.fromBlock, privacy: .public) \
      continuation \(pageKey != nil, privacy: .public)
      """
    )

    let data = try await send(request: request, stage: "getAssetTransfers")
    do {
      return try JSONDecoder().decode(
        AlchemyTransferEnvelope.self, from: data
      ).result
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
    body: AlchemyJSONRPCRequest<Params>,
    apiKey: String
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
    try AlchemyResponseValidator.validate(
      response: response, stage: stage, logger: logger)
  }
}
