import SwiftUI

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

/// "On-chain counterparty" section in the transaction detail. Shown when
/// at least one of the transaction's legs has a non-nil
/// `counterpartyAddress` (the lowercased hex address recorded by the
/// wallet importer for the *other* side of the transfer).
///
/// We deliberately render this as a copyable address row rather than a
/// clickable link: an arbitrary on-chain address is not authoritative
/// (no human-readable identity, no provenance guarantee), and making it
/// look like a navigable link would mislead the user. The block-explorer
/// section a few rows above already provides the "go look this up"
/// affordance for the *transaction*; this section is just structured
/// data the user might want to copy.
///
/// The address is rendered in full — never truncated. A `0xabcd…wxyz`
/// abbreviation is unsafe to verify against because an attacker can
/// vanity-mine an address whose prefix and suffix match a target.
struct TransactionDetailCounterpartySection: View {
  let transaction: Transaction

  /// Legs with a non-nil counterparty address, paired with the leg's
  /// instrument label (used to disambiguate per-leg labels in the
  /// multi-leg case). Computed once per render.
  private var entries: [Entry] {
    transaction.legs.enumerated().compactMap { index, leg -> Entry? in
      guard let address = leg.counterpartyAddress else { return nil }
      return Entry(
        legIndex: index, address: address, ticker: leg.instrument.displayLabel)
    }
  }

  /// Whether the section should render at all. Hidden when no leg has a
  /// counterparty so the section header doesn't appear empty.
  var isApplicable: Bool { !entries.isEmpty }

  var body: some View {
    if isApplicable {
      let legs = entries
      Section("On-chain counterparty") {
        ForEach(legs) { entry in
          counterpartyRow(for: entry, totalLegs: legs.count)
        }
      }
    }
  }

  @ViewBuilder
  private func counterpartyRow(for entry: Entry, totalLegs: Int) -> some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        if totalLegs > 1 {
          Text(entry.ticker)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Text(entry.address)
          .font(.body.monospaced())
          .textSelection(.enabled)
      }
      Spacer()
      Button {
        Self.copy(entry.address)
      } label: {
        Label("Copy address", systemImage: "doc.on.doc")
          .labelStyle(.iconOnly)
      }
      .buttonStyle(.borderless)
      .accessibilityLabel("Copy counterparty address")
      .accessibilityIdentifier(
        UITestIdentifiers.Detail.counterpartyCopyButton(legIndex: entry.legIndex))
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityLabel(for: entry, totalLegs: totalLegs))
    .accessibilityIdentifier(
      UITestIdentifiers.Detail.counterpartyAddress(legIndex: entry.legIndex))
  }

  /// Full-address VoiceOver label that disambiguates per-leg rows in the
  /// multi-leg case ("ETH counterparty 0x…") and stays terse in the
  /// common single-leg case.
  private func accessibilityLabel(for entry: Entry, totalLegs: Int) -> String {
    totalLegs == 1
      ? "On-chain counterparty: \(entry.address)"
      : "\(entry.ticker) counterparty: \(entry.address)"
  }

  /// Writes the address to the platform pasteboard. Copy is a side effect
  /// the user explicitly invoked (button tap), so no confirmation UI is
  /// needed.
  static func copy(_ address: String) {
    #if canImport(UIKit)
      UIPasteboard.general.string = address
    #elseif canImport(AppKit)
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(address, forType: .string)
    #endif
  }

  /// One renderable row. `legIndex` doubles as the `Identifiable` id —
  /// stable across re-renders because the leg order is fixed by the
  /// transaction.
  private struct Entry: Identifiable {
    let legIndex: Int
    let address: String
    let ticker: String
    var id: Int { legIndex }
  }
}
