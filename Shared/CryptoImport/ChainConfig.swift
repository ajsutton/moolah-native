// Shared/CryptoImport/ChainConfig.swift
import Foundation

/// Per-chain config for the crypto wallet importer.
///
/// v1 covers Ethereum, OP Mainnet, Base, and Polygon. Extending to other EVM
/// chains (Arbitrum, Avalanche, …) is purely additive — add a new entry to
/// `all`. See `plans/2026-05-05-crypto-wallet-import-design.md` for the
/// open question on `internal` transfer-category support across chains.
struct ChainConfig: Sendable, Hashable {
  /// EVM chain identifier (e.g. 1 for Ethereum mainnet).
  let chainId: Int

  /// Alchemy network slug, e.g. `eth-mainnet`, `opt-mainnet`,
  /// `base-mainnet`, `polygon-mainnet`. Used as the path component for the
  /// JSON-RPC endpoint hostname (`https://<slug>.g.alchemy.com/v2/<key>`).
  let alchemyNetworkSlug: String

  /// The instrument used as the chain's native token (gas) — ETH for
  /// Ethereum / OP / Base; MATIC for Polygon.
  let nativeInstrument: Instrument

  /// `true` if Alchemy supports the `internal` transfer category on this
  /// chain (Ethereum, Polygon). OP / Base do NOT support `internal` — see
  /// design open question 3.
  let supportsInternalTransfers: Bool

  /// Block-explorer base URL (no trailing slash). Used by
  /// `BlockExplorerLink` to render outbound transaction links.
  let blockExplorerBaseURL: URL

  /// Human-readable name for the chain picker / settings UI.
  let displayName: String

  /// All supported chains, indexed by `chainId` order. The chain
  /// picker renders this in declaration order; stable across launches.
  static let all: [ChainConfig] = [
    .ethereum, .optimism, .base, .polygon,
  ]

  /// Lookup by EVM chain ID. Returns `nil` for unsupported chains.
  static func config(for chainId: Int) -> ChainConfig? {
    all.first { $0.chainId == chainId }
  }
}

extension ChainConfig {
  /// Ethereum mainnet — chain 1. Native token: ETH (18 decimals).
  /// Supports the `internal` transfer category.
  static let ethereum = ChainConfig(
    chainId: 1,
    alchemyNetworkSlug: "eth-mainnet",
    nativeInstrument: Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18),
    supportsInternalTransfers: true,
    blockExplorerBaseURL: requireURL("https://etherscan.io"),
    displayName: "Ethereum"
  )

  /// OP Mainnet (Optimism) — chain 10. Native token: ETH (18 decimals).
  /// Does NOT support the `internal` transfer category.
  static let optimism = ChainConfig(
    chainId: 10,
    alchemyNetworkSlug: "opt-mainnet",
    nativeInstrument: Instrument.crypto(
      chainId: 10, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18),
    supportsInternalTransfers: false,
    blockExplorerBaseURL: requireURL("https://optimistic.etherscan.io"),
    displayName: "OP Mainnet"
  )

  /// Base — chain 8453. Native token: ETH (18 decimals).
  /// Does NOT support the `internal` transfer category.
  static let base = ChainConfig(
    chainId: 8453,
    alchemyNetworkSlug: "base-mainnet",
    nativeInstrument: Instrument.crypto(
      chainId: 8453, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18),
    supportsInternalTransfers: false,
    blockExplorerBaseURL: requireURL("https://basescan.org"),
    displayName: "Base"
  )

  /// Polygon PoS — chain 137. Native token: MATIC (18 decimals).
  /// Supports the `internal` transfer category.
  static let polygon = ChainConfig(
    chainId: 137,
    alchemyNetworkSlug: "polygon-mainnet",
    nativeInstrument: Instrument.crypto(
      chainId: 137, contractAddress: nil, symbol: "MATIC", name: "Polygon", decimals: 18),
    supportsInternalTransfers: true,
    blockExplorerBaseURL: requireURL("https://polygonscan.com"),
    displayName: "Polygon"
  )

  /// Compile-time URL constructor. The hardcoded literals above are valid
  /// URLs by inspection; a `nil` here is a programmer error rather than a
  /// runtime failure mode, so `preconditionFailure` is the honest spelling
  /// (we don't want to paper over a typo with a bogus fallback URL).
  private static func requireURL(_ string: String) -> URL {
    guard let url = URL(string: string) else {
      preconditionFailure("ChainConfig: malformed URL literal \(string)")
    }
    return url
  }
}
