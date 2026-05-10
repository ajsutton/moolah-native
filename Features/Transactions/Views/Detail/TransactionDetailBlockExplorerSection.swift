import SwiftUI

/// "Block explorer" section in the transaction detail. Shown when at
/// least one of the transaction's legs has an `externalId` (the on-chain
/// tx hash recorded by the wallet importer) and a resolvable chain id.
/// One link per **unique on-chain hash**: a wallet-imported transaction
/// typically has multiple legs (e.g. transfer + gas) that all share the
/// same hash, so a single explorer link covers the whole transaction.
/// On the rare path where legs span multiple hashes, each unique URL
/// renders once.
///
/// We deliberately render this as plain `Link` rows rather than a
/// stylised "Open in Etherscan" pill: explorers across chains use
/// different domains, and the brand-neutral "View on block explorer"
/// label avoids privileging any one service in our UI.
struct TransactionDetailBlockExplorerSection: View {
  let transaction: Transaction

  /// Whether the section should render at all. Hidden when no leg has
  /// a usable explorer link so the section header doesn't appear empty.
  var isApplicable: Bool { !Self.explorerURLs(for: transaction.legs).isEmpty }

  var body: some View {
    let urls = Self.explorerURLs(for: transaction.legs)
    if !urls.isEmpty {
      Section("Block Explorer") {
        ForEach(urls, id: \.self) { url in
          Link(destination: url) {
            Label("View on block explorer", systemImage: "arrow.up.right.square")
          }
          .accessibilityIdentifier(UITestIdentifiers.Detail.blockExplorerLink)
        }
      }
    }
  }

  /// Distinct block-explorer URLs for the supplied legs in first-seen
  /// order. The `externalId` overload strips the `<category>:<index>`
  /// (transfer leg) or `gas` (gas leg) suffix to recover the bare
  /// on-chain hash the explorer expects — issue #848. The per-URL
  /// dedup collapses the usual transfer-plus-gas pair (sharing one
  /// hash) down to a single row, matching the user's mental model
  /// that one transaction = one explorer link.
  ///
  /// `nonisolated` so the dedup logic is testable from a non-MainActor
  /// suite without spinning up a SwiftUI context. Also exposed as a
  /// static helper because the view is `@MainActor` and the body's
  /// "is the section worth rendering" guard wants to share the same
  /// computation that produces the rows.
  nonisolated static func explorerURLs(for legs: [TransactionLeg]) -> [URL] {
    var seen: Set<URL> = []
    var result: [URL] = []
    for leg in legs {
      guard let externalId = leg.externalId,
        let chainId = leg.instrument.chainId,
        let url = BlockExplorerLink.transactionURL(chainId: chainId, externalId: externalId)
      else { continue }
      if seen.insert(url).inserted {
        result.append(url)
      }
    }
    return result
  }
}
