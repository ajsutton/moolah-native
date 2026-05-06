import SwiftUI

/// "Block explorer" section in the transaction detail. Shown when at
/// least one of the transaction's legs has an `externalId` (the on-chain
/// tx hash recorded by the wallet importer) and a resolvable chain id.
/// One link per qualifying leg — for a multi-leg merged transfer with
/// gas + value legs sharing the same hash, both legs render their own
/// row so the user can see explicit per-leg provenance.
///
/// We deliberately render this as plain `Link` rows rather than a
/// stylised "Open in Etherscan" pill: explorers across chains use
/// different domains, and the brand-neutral "View on block explorer"
/// label avoids privileging any one service in our UI.
struct TransactionDetailBlockExplorerSection: View {
  let transaction: Transaction

  /// Legs with both an `externalId` and a chain id resolvable via
  /// `ChainConfig`, paired with their canonical explorer URL.
  /// Computed once per render so the body is straight-line code.
  private var entries: [Entry] {
    transaction.legs.enumerated().compactMap { index, leg -> Entry? in
      guard let externalId = leg.externalId,
        let chainId = leg.instrument.chainId,
        let url = BlockExplorerLink.transactionURL(chainId: chainId, hash: externalId)
      else { return nil }
      return Entry(legIndex: index, url: url, ticker: leg.instrument.displayLabel)
    }
  }

  /// Whether the section should render at all. Hidden when no leg has a
  /// usable explorer link so the section header doesn't appear empty.
  var isApplicable: Bool { !entries.isEmpty }

  var body: some View {
    if isApplicable {
      let legs = entries
      Section("Block Explorer") {
        ForEach(legs) { entry in
          Link(destination: entry.url) {
            Label("View on block explorer", systemImage: "arrow.up.right.square")
              .accessibilityLabel(accessibilityLabel(for: entry, totalLegs: legs.count))
          }
          .accessibilityIdentifier(
            UITestIdentifiers.Detail.blockExplorerLink(legIndex: entry.legIndex))
        }
      }
    }
  }

  /// VoiceOver label that disambiguates per-leg links in the multi-leg
  /// case ("View ETH leg on block explorer") and stays terse in the
  /// common single-leg case ("View on block explorer").
  private func accessibilityLabel(for entry: Entry, totalLegs: Int) -> String {
    totalLegs == 1
      ? "View on block explorer"
      : "View \(entry.ticker) leg on block explorer"
  }

  /// One renderable row. `legIndex` doubles as the `Identifiable` id —
  /// stable across re-renders because the leg order is fixed by the
  /// transaction.
  private struct Entry: Identifiable {
    let legIndex: Int
    let url: URL
    let ticker: String
    var id: Int { legIndex }
  }
}
