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
    let body = AlchemyJSONRPCRequest<AlchemyJSONRPCParams>(
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
    let request = try buildRequest(chain: chain, body: body)
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
    let body = AlchemyJSONRPCRequest<AlchemyJSONRPCParams>(
      method: "alchemy_getAssetTransfers",
      params: .assetTransfers(
        AlchemyAssetTransfersParams(
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
    body: AlchemyJSONRPCRequest<Params>
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
