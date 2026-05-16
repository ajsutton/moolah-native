// Shared/CryptoImport/BlockExplorerClient.swift
import Foundation
import OSLog
import os

/// Block-explorer source for native-ETH enumeration. Blockscout's
/// public API is indexed by *transaction* (and exposes
/// contract-internal transfers), so unlike Alchemy's Transfer-log
/// index it surfaces zero-value / `approve()` / failed signed txs
/// (#919) and OP-stack internal ETH credits (#918). No API key — the
/// public instances are unauthenticated.
protocol BlockExplorerClient: Sendable {
  /// Every transaction touching `walletAddress` (as `from` or `to`),
  /// newest-first, paginated until the cursor is absent or a page
  /// predates `fromBlock`. Includes failed / zero-value / `approve()`
  /// txs — they are real signed txs that paid gas.
  func nativeTransactions(
    chain: ChainConfig, walletAddress: String, fromBlock: UInt64
  ) async throws -> [BlockscoutTransaction]

  /// Contract-internal ETH transfers touching `walletAddress`, same
  /// pagination contract. This is the data Alchemy cannot index on
  /// OP-stack chains (#918).
  func internalTransactions(
    chain: ChainConfig, walletAddress: String, fromBlock: UInt64
  ) async throws -> [BlockscoutInternalTx]
}

/// Live `BlockExplorerClient` over Blockscout's public v2 REST API.
/// `Sendable` struct with no mutable state — mirrors `LiveAlchemyClient`.
struct LiveBlockscoutClient: Sendable {
  private let session: URLSession
  private let rateLimiter: RateLimiter
  private let logger: Logger

  init(session: URLSession = .shared, rateLimiter: RateLimiter) {
    self.session = session
    self.rateLimiter = rateLimiter
    self.logger = Logger(subsystem: "com.moolah.app", category: "BlockscoutClient")
  }

  // MARK: - Internals

  // Per-endpoint configuration for the generic Blockscout cursor-loop paginator: the URL path
  // suffix, log-stage tag, page decoder, item accessor, cursor extractor, and per-item
  // block-number accessor for one paginated Blockscout endpoint.
  private struct PaginateConfig<Page, Item> {
    let pathSuffix: String
    let stage: String
    let decode: (Data) throws -> Page
    let items: (Page) -> [Item]
    let cursor: (Page) -> BlockscoutPageParams?
    let blockNumber: (Item) -> Int
  }

  /// Generic cursor loop shared by both endpoints. Stops when the cursor
  /// is absent, when a page is empty, when a `BlockscoutPageParams` cursor
  /// repeats (misbehaving provider guard, mirrors `LiveAlchemyClient`), or
  /// once every item on a page predates `fromBlock` (newest-first ordering
  /// means nothing older remains worth fetching).
  private func paginate<Page, Item>(
    chain: ChainConfig,
    walletAddress: String,
    fromBlock: UInt64,
    config: PaginateConfig<Page, Item>
  ) async throws -> [Item] {
    let signpostID = OSSignpostID(log: Signposts.cryptoSync)
    os_signpost(
      .begin,
      log: Signposts.cryptoSync,
      name: "blockscout.fetch",
      signpostID: signpostID,
      "chain %{public}d",
      chain.chainId)
    defer {
      os_signpost(
        .end,
        log: Signposts.cryptoSync,
        name: "blockscout.fetch",
        signpostID: signpostID)
    }
    var collected: [Item] = []
    var pageParams: BlockscoutPageParams?
    var seenCursors: Set<BlockscoutPageParams> = []
    while true {
      if let pageParams, !seenCursors.insert(pageParams).inserted { break }
      try await rateLimiter.acquire()
      let request = try buildRequest(
        chain: chain,
        walletAddress: walletAddress,
        pathSuffix: config.pathSuffix,
        pageParams: pageParams)
      let data = try await send(request: request, stage: config.stage)
      let page: Page
      do {
        page = try config.decode(data)
      } catch {
        logger.error(
          "Blockscout \(config.stage, privacy: .public) decode failed for chain \(chain.chainId, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
        throw WalletSyncError.providerMalformedResponse(stage: config.stage)
      }
      let pageItems = config.items(page)
      if pageItems.isEmpty { break }
      collected.append(contentsOf: pageItems)
      // Newest-first: if the whole page is older than fromBlock, stop.
      if pageItems.allSatisfy({ UInt64(config.blockNumber($0).magnitude) < fromBlock }) {
        break
      }
      guard let next = config.cursor(page) else { break }
      pageParams = next
    }
    return collected
  }

  private func buildRequest(
    chain: ChainConfig,
    walletAddress: String,
    pathSuffix: String,
    pageParams: BlockscoutPageParams?
  ) throws -> URLRequest {
    guard
      var components = URLComponents(
        url: chain.blockscoutAPIBaseURL, resolvingAgainstBaseURL: false)
    else {
      throw WalletSyncError.network(
        underlyingDescription: "Malformed Blockscout base URL for chain \(chain.chainId)")
    }
    components.path = "/api/v2/addresses/\(walletAddress)/\(pathSuffix)"
    let cursorItems = pageParams?.queryItems ?? []
    components.queryItems = cursorItems.isEmpty ? nil : cursorItems
    guard let url = components.url else {
      throw WalletSyncError.network(
        underlyingDescription: "Malformed Blockscout URL for chain \(chain.chainId)")
    }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    // Hash/address is `.private`; chain is `.public` — matches the
    // Alchemy client's privacy table.
    logger.debug(
      "Blockscout GET chain \(chain.chainId, privacy: .public) \(pathSuffix, privacy: .public) address \(walletAddress, privacy: .private) paged \(pageParams != nil, privacy: .public)"
    )
    return request
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
        "Blockscout \(stage, privacy: .public) network failure: \(error.localizedDescription, privacy: .public)"
      )
      throw WalletSyncError.network(underlyingDescription: error.localizedDescription)
    }
    do {
      try AlchemyResponseValidator.validate(response: response, stage: stage, logger: logger)
    } catch WalletSyncError.invalidApiKey {
      logger.error(
        "Blockscout \(stage, privacy: .public): HTTP 401/403 (public API expects no auth)")
      throw WalletSyncError.network(underlyingDescription: "HTTP 401/403")
    }
    return data
  }
}

extension LiveBlockscoutClient: BlockExplorerClient {
  func nativeTransactions(
    chain: ChainConfig, walletAddress: String, fromBlock: UInt64
  ) async throws -> [BlockscoutTransaction] {
    try await paginate(
      chain: chain,
      walletAddress: walletAddress,
      fromBlock: fromBlock,
      config: PaginateConfig(
        pathSuffix: "transactions",
        stage: "blockscout.transactions",
        decode: { try JSONDecoder().decode(BlockscoutTransactionsPage.self, from: $0) },
        items: { $0.items },
        cursor: { $0.nextPageParams },
        blockNumber: { $0.blockNumber }))
  }

  func internalTransactions(
    chain: ChainConfig, walletAddress: String, fromBlock: UInt64
  ) async throws -> [BlockscoutInternalTx] {
    try await paginate(
      chain: chain,
      walletAddress: walletAddress,
      fromBlock: fromBlock,
      config: PaginateConfig(
        pathSuffix: "internal-transactions",
        stage: "blockscout.internalTransactions",
        decode: { try JSONDecoder().decode(BlockscoutInternalTxPage.self, from: $0) },
        items: { $0.items },
        cursor: { $0.nextPageParams },
        blockNumber: { $0.blockNumber }))
  }
}
