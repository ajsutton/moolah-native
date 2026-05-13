// swiftlint:disable multiline_arguments

import SwiftUI

/// Responsive table of `ValuedPosition`s. On wide layouts (macOS, regular iOS
/// width) renders a `Table` with sortable columns. On compact layouts falls
/// back to a `List` of `PositionRow`s.
///
/// Group subtotals only render when more than one `Instrument.Kind` is
/// present (per `PositionsViewInput.showsGroupSubtotals`).
struct PositionsTable: View {
  let input: PositionsViewInput
  @Binding var selection: Instrument?

  @Environment(\.horizontalSizeClass) private var sizeClass

  @State private var sortOrder: [KeyPathComparator<ValuedPosition>] = [
    .init(\.valueQuantity, order: .reverse)
  ]

  /// macOS-only Grid sort state. Lives alongside `sortOrder` (the iOS
  /// Table's `KeyPathComparator` array) — the two states never both
  /// drive layout because the `#if os(macOS)` branch in `body` chooses
  /// one or the other.
  ///
  /// The macOS Grid state below uses `internal` access (not `private`)
  /// because the rendering helpers live in
  /// `PositionsTable+GridLayout.swift` and Swift extensions in another
  /// file cannot see `private` members.
  #if os(macOS)
    @State var sort = PositionsSortState(column: .value, direction: .descending)
    @Environment(\.dynamicTypeSize) var dynamicTypeSize

    /// Tracks whether the macOS Grid panel currently owns keyboard
    /// focus. Driven by `.focusable()` + `.focused($isPanelFocused)`.
    /// On focus-gain we seed `focusedRowIndex` to 0; on focus-loss we
    /// clear it so the focus ring disappears when the user Tabs out.
    @FocusState var isPanelFocused: Bool

    /// Which row inside the panel the keyboard cursor is on. `nil`
    /// means no row is focused (panel doesn't own focus yet, or the
    /// row list is empty). Driven by Up/Down arrow key presses.
    @State var focusedRowIndex: Int?

    /// Which row the pointer is hovering over, by index. Single source
    /// of truth for hover-tint rendering — per-row `@State isHovered`
    /// on a custom `View` row struct can't work because SwiftUI's
    /// `Grid` requires `GridRow` to be a direct child for column
    /// alignment, so the row chrome lives inline in `macOSGridLayout`
    /// with no per-row View to hang local state on.
    @State var hoveredRowIndex: Int?

    /// Window-key state read so the row background can swap between
    /// `selectedContentBackgroundColor` (key) and the
    /// `unemphasizedSelected…` variant (not key). AppKit's
    /// `NSTableView` swaps these automatically; SwiftUI's
    /// `Color(nsColor:)` is static, so the swap is driven here.
    @Environment(\.controlActiveState) var controlActiveState
  #endif

  var body: some View {
    Group {
      #if os(macOS)
        if dynamicTypeSize > .xLarge {
          narrowLayout
        } else {
          macOSGridLayout
        }
      #else
        if sizeClass == .regular {
          wideLayout
        } else {
          narrowLayout
        }
      #endif
    }
  }

  /// Internal (not private) so the macOS Grid extension in
  /// `PositionsTable+GridLayout.swift` can read it.
  var groups: [InstrumentGroup] {
    InstrumentGroup.make(from: input.positions)
  }

  // MARK: - macOS Grid
  //
  // The macOS Grid rendering path (`macOSGridLayout`, `headerRow`,
  // `sortHeader`, `toggleSelection`, the accessibility-representation
  // bindings and helpers, and the `KeyPathComparator` ↔ sort-state
  // translators) lives in `PositionsTable+GridLayout.swift` to keep this
  // file inside SwiftLint's `file_length` / `type_body_length`
  // thresholds. The `@State` / `@FocusState` / `@Environment` properties
  // driving that code path stay declared here above because Swift
  // forbids stored properties in extensions.

  // MARK: - Wide

  @ViewBuilder private var wideLayout: some View {
    let sortedRows = groups.flatMap(\.rows).sorted(using: sortOrder)
    Table(sortedRows, selection: rowSelectionBinding, sortOrder: $sortOrder) {
      TableColumn("Instrument", value: \.instrument.name) { row in
        instrumentCell(for: row)
      }
      TableColumn("Qty", value: \.quantity) { row in
        Text(row.quantityFormatted).monospacedDigit()
      }
      TableColumn("Unit Price", value: \.unitPriceQuantity) { row in
        amountCell(row.unitPrice)
      }
      TableColumn("Cost", value: \.costBasisQuantity) { row in
        amountCell(row.costBasis)
      }
      TableColumn("Value", value: \.valueQuantity) { row in
        amountCell(row.value)
      }
      TableColumn("Gain", value: \.gainQuantity) { row in
        gainCell(row)
      }
    }
  }

  // MARK: - Narrow

  @ViewBuilder private var narrowLayout: some View {
    List(selection: narrowSelectionBinding) {
      ForEach(groups) { group in
        groupContent(for: group)
      }
    }
    #if !os(macOS)
      .listStyle(.plain)
    #endif
  }
}

// MARK: - Internal helpers shared with PositionsTable+GridLayout

/// Internal-access helpers used by both the iOS Table path (in this
/// file) and the macOS Grid path (in `PositionsTable+GridLayout.swift`).
/// Kept in a non-private trailing extension so the access widening is
/// visually obvious — `private extension` below holds the rest of the
/// file-local helpers.
extension PositionsTable {
  /// Accessibility label combining the dollar gain and percent: e.g.
  /// "gain of $1,200, up 12.3 percent" / "loss of $50, down 5.0 percent".
  /// Per `guides/UI_GUIDE.md` every gain renders an explicit
  /// accessibility label so VoiceOver doesn't read "+12%" as ambiguous.
  ///
  /// Internal (not private) so the macOS Grid extension in
  /// `PositionsTable+GridLayout.swift` can delegate its
  /// `accessibilityGainText(for:)` here — one source of truth for the
  /// gain-phrase construction across both rendering paths.
  func gainAccessibilityLabel(
    gain: InstrumentAmount, percent: Decimal?
  ) -> String {
    let pctText = GainLossPercentDisplay.accessibilitySuffix(percent)
    if gain.isNegative {
      return "loss of \((-gain).formatted)\(pctText)"
    }
    if gain.isZero {
      return pctText.isEmpty ? "no change" : "no change\(pctText)"
    }
    return "gain of \(gain.formatted)\(pctText)"
  }

  /// `Table` selects on `id` (which is `instrument.id`); we adapt that to
  /// our `Instrument?` selection binding.
  ///
  /// Internal (not private) so the macOS Grid extension in
  /// `PositionsTable+GridLayout.swift` can route its
  /// `.accessibilityRepresentation` Table through the same selection
  /// bridge — avoids byte-identical duplication between the iOS Table
  /// path and the macOS accessibility-Table path.
  var rowSelectionBinding: Binding<Set<String>> {
    Binding(
      get: { selection.map { [$0.id] } ?? [] },
      set: { ids in
        if let id = ids.first,
          let instrument = input.positions.first(where: { $0.id == id })?.instrument
        {
          selection = (selection?.id == id) ? nil : instrument
        } else {
          selection = nil
        }
      }
    )
  }

  /// Accessibility label combining the instrument name, kind word, and
  /// exchange (when present). e.g. "BHP, Stock, ASX" / "AUD, Cash".
  ///
  /// Internal (not private) so the macOS Grid extension in
  /// `PositionsTable+GridLayout.swift` can delegate its
  /// accessibility-Table instrument cells here — one source of truth so
  /// the iOS Table path and the macOS accessibility-Table path read
  /// identical phrasing to VoiceOver.
  func instrumentLabel(for row: ValuedPosition) -> String {
    let kindWord: String = {
      switch row.instrument.kind {
      case .stock: return "Stock"
      case .cryptoToken: return "Crypto"
      case .fiatCurrency: return "Cash"
      }
    }()
    if let exchange = row.instrument.exchange {
      return "\(row.instrument.name), \(kindWord), \(exchange)"
    }
    return "\(row.instrument.name), \(kindWord)"
  }
}

// MARK: - Private file-local helpers

/// File-local helpers grouped here per CODE_GUIDE.md §2 ("Trailing
/// `private extension Self` for file-private helpers"). Members are
/// only reachable from the iOS Table path and the narrow `List` path in
/// the main type body above. Uses `extension Self { private func … }`
/// rather than `private extension Self { func … }` to match the
/// project convention and avoid swift-format rewriting members to
/// `fileprivate` (which `strict_fileprivate` then flags).
extension PositionsTable {
  // MARK: Wide-layout (iOS Table) cell builders

  @ViewBuilder
  private func instrumentCell(for row: ValuedPosition) -> some View {
    HStack(spacing: 6) {
      KindBadge(kind: row.instrument.kind)
      VStack(alignment: .leading) {
        Text(row.instrument.name)
        if let exchange = row.instrument.exchange {
          Text(exchange).font(.caption).foregroundStyle(.secondary)
        }
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(instrumentLabel(for: row))
  }

  @ViewBuilder
  private func amountCell(_ amount: InstrumentAmount?) -> some View {
    if let amount {
      Text(amount.formatted).monospacedDigit()
    } else {
      Text("—").foregroundStyle(.tertiary)
    }
  }

  @ViewBuilder
  private func gainCell(_ row: ValuedPosition) -> some View {
    if let gain = row.gainLoss {
      HStack(spacing: 4) {
        Text(gain.signedFormatted)
          .monospacedDigit()
          .foregroundStyle(gain.gainColor)
        if let pct = row.gainLossPercent {
          Text(GainLossPercentDisplay.formatted(pct))
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(gain.gainColor)
        }
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel(gainAccessibilityLabel(gain: gain, percent: row.gainLossPercent))
    } else {
      Text("—").foregroundStyle(.tertiary)
    }
  }

  // MARK: Narrow-layout (List) helpers

  @ViewBuilder
  private func groupContent(for group: InstrumentGroup) -> some View {
    if input.showsGroupSubtotals {
      Section(group.title) {
        ForEach(group.rows) { row in
          PositionRow(row: row).tag(row.id)
        }
      }
    } else {
      ForEach(group.rows) { row in
        PositionRow(row: row).tag(row.id)
      }
    }
  }

  private var narrowSelectionBinding: Binding<String?> {
    Binding(
      get: { selection?.id },
      set: { id in
        if let id, let instrument = input.positions.first(where: { $0.id == id })?.instrument {
          selection = (selection?.id == id) ? nil : instrument
        } else {
          selection = nil
        }
      }
    )
  }

}

private func mixedPositionsInput() -> PositionsViewInput {
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
  let cba = Instrument.stock(ticker: "CBA.AX", exchange: "ASX", name: "CBA")
  let eth = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
  let aud = Instrument.AUD
  return PositionsViewInput(
    title: "Brokerage", hostCurrency: aud,
    positions: [
      ValuedPosition(
        instrument: bhp, quantity: 250,
        unitPrice: InstrumentAmount(quantity: 45.30, instrument: aud),
        costBasis: InstrumentAmount(quantity: 10_125, instrument: aud),
        value: InstrumentAmount(quantity: 11_325, instrument: aud)),
      ValuedPosition(
        instrument: cba, quantity: 80,
        unitPrice: InstrumentAmount(quantity: 120, instrument: aud),
        costBasis: InstrumentAmount(quantity: 9_000, instrument: aud),
        value: InstrumentAmount(quantity: 9_600, instrument: aud)),
      ValuedPosition(
        instrument: eth, quantity: 2.45,
        unitPrice: InstrumentAmount(quantity: 4_000, instrument: aud),
        costBasis: InstrumentAmount(quantity: 7_500, instrument: aud),
        value: InstrumentAmount(quantity: 9_800, instrument: aud)),
      ValuedPosition(
        instrument: aud, quantity: 2_480,
        unitPrice: nil, costBasis: nil,
        value: InstrumentAmount(quantity: 2_480, instrument: aud)),
    ],
    historicalValue: nil)
}

#Preview("PositionsTable - mixed wide") {
  PositionsTable(input: mixedPositionsInput(), selection: .constant(nil))
    .frame(width: 720, height: 360)
}

#Preview("PositionsTable - conversion failure") {
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
  let aud = Instrument.AUD
  let input = PositionsViewInput(
    title: "Brokerage",
    hostCurrency: aud,
    positions: [
      ValuedPosition(
        instrument: bhp, quantity: 250,
        unitPrice: nil, costBasis: nil, value: nil)
    ],
    historicalValue: nil
  )
  return PositionsTable(input: input, selection: .constant(nil))
    .frame(width: 720, height: 240)
}
