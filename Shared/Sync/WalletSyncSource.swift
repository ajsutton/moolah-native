import Foundation

/// Minimal seam over the concrete `WalletSyncEngine` so `WalletSyncSource`
/// is testable without an Alchemy client. `: Sendable` is required —
/// `WalletSyncSource` is `Sendable` and stores `any WalletSyncBuilding`,
/// so Swift 6 strict concurrency rejects the conformance without it. The
/// real engine is already a `Sendable` struct; it conforms via a
/// one-line extension (see `WalletSyncEngine+WalletSyncBuilding.swift`).
protocol WalletSyncBuilding: Sendable {
  func build(account: Account, chain: ChainConfig) async throws -> WalletSyncBuildResult
}

/// `AccountSyncSource` for on-chain wallet accounts. Wraps the existing
/// `WalletSyncEngine` + `ChainConfig` lookup — no behaviour change, just
/// the crypto path expressed through the shared protocol.
struct WalletSyncSource: AccountSyncSource, Sendable {
  private let engine: any WalletSyncBuilding
  private let chains: [ChainConfig]

  init(engine: any WalletSyncBuilding, chains: [ChainConfig] = ChainConfig.all) {
    self.engine = engine
    self.chains = chains
  }

  func handles(_ account: Account) -> Bool {
    account.type == .crypto
      && account.walletAddress.map { !$0.isEmpty } == true
      && chain(for: account) != nil
  }

  func build(account: Account) async throws -> WalletSyncBuildResult {
    guard let chain = chain(for: account) else {
      throw WalletSyncError.providerMalformedResponse(stage: "chain-lookup")
    }
    return try await engine.build(account: account, chain: chain)
  }

  // Resolve from the INJECTED chains (not the global `ChainConfig.config`),
  // so the source is testable with stubbed chains and `chains` is real DI.
  private func chain(for account: Account) -> ChainConfig? {
    guard let chainId = account.chainId else { return nil }
    return chains.first { $0.chainId == chainId }
  }
}
