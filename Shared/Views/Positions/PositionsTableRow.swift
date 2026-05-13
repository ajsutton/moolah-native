import SwiftUI

#if os(macOS)

  /// One Grid row inside `PositionsTable.macOSGridLayout`. Owns its
  /// own hover state so SwiftUI's diffing keeps hover-only re-renders
  /// scoped to a single row. Reads `@Environment(\.controlActiveState)`
  /// so the selection background swaps between
  /// `selectedContentBackgroundColor` and
  /// `unemphasizedSelectedContentBackgroundColor` when the window loses
  /// key state — native `NSTableView` swaps these automatically but
  /// SwiftUI's `Color(nsColor:)` is static, so the swap is driven here.
  ///
  /// Accessibility shape: this view carries **no** per-cell or per-row
  /// accessibility config — the parent's
  /// `.accessibilityRepresentation { Table(...) }` replaces the Grid's
  /// entire accessibility tree with a native `Table`, which advertises
  /// the "Table" trait, column headers, and row navigation to VoiceOver
  /// out of the box.
  struct PositionsTableRow: View {
    let row: ValuedPosition
    let isSelected: Bool
    let isFocused: Bool
    let isAlternateRow: Bool
    let toggleSelection: () -> Void

    @State private var isHovered = false
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
      GridRow(alignment: .firstTextBaseline) {
        instrumentCell
        Text(row.quantityFormatted)
          .monospacedDigit()
          .gridColumnAlignment(.trailing)
        amountCell(row.unitPrice)
          .gridColumnAlignment(.trailing)
        amountCell(row.costBasis)
          .gridColumnAlignment(.trailing)
        amountCell(row.value)
          .gridColumnAlignment(.trailing)
        gainCell
          .gridColumnAlignment(.trailing)
          .frame(minWidth: 140, alignment: .trailing)
      }
      .padding(.vertical, 6)
      .padding(.horizontal, 8)
      .background(
        Self.rowBackground(
          isSelected: isSelected,
          isHovered: isHovered,
          isWindowKey: controlActiveState == .key,
          isAlternateRow: isAlternateRow)
      )
      .overlay(focusRing)
      .contentShape(Rectangle())
      .onTapGesture { toggleSelection() }
      .onHover { isHovered = $0 }
    }

    /// Keyboard-focus ring drawn on top of the row when this row is the
    /// `focusedRowIndex` in the parent panel. Mirrors the macOS
    /// system focus appearance: 2pt accent-coloured rounded rect.
    /// Conditionally rendered so unfocused rows don't pay the modifier
    /// cost.
    @ViewBuilder private var focusRing: some View {
      if isFocused {
        RoundedRectangle(cornerRadius: 4)
          .stroke(Color.accentColor, lineWidth: 2)
      }
    }

    // MARK: - Cells

    @ViewBuilder private var instrumentCell: some View {
      HStack(spacing: 6) {
        KindBadge(kind: row.instrument.kind)
        VStack(alignment: .leading) {
          Text(row.instrument.name)
          if let exchange = row.instrument.exchange {
            Text(exchange).font(.caption).foregroundStyle(.secondary)
          }
        }
      }
    }

    @ViewBuilder
    private func amountCell(_ amount: InstrumentAmount?) -> some View {
      if let amount {
        Text(amount.formatted).monospacedDigit()
      } else {
        Text("—").foregroundStyle(.tertiary)
      }
    }

    @ViewBuilder private var gainCell: some View {
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
      } else {
        Text("—").foregroundStyle(.tertiary)
      }
    }

    // MARK: - Background

    /// Resolves the row background from AppKit semantic tokens —
    /// `selectedContentBackgroundColor` (key window), the
    /// `unemphasizedSelected…` variant (window not key),
    /// `controlAccentColor.opacity(0.10)` (hover — the published
    /// `NSTableRowView` convention since AppKit has no single "row
    /// hover" semantic colour), and `alternatingContentBackgroundColors[0|1]`
    /// (zebra striping — system-resolved so Increase Contrast disables
    /// striping for free).
    ///
    /// `isWindowKey` is whether the host window currently owns key
    /// status (`controlActiveState == .key`) — distinct from
    /// `PositionsTableRow.isFocused`, which is the keyboard cursor
    /// position inside the panel.
    private static func rowBackground(
      isSelected: Bool,
      isHovered: Bool,
      isWindowKey: Bool,
      isAlternateRow: Bool
    ) -> Color {
      if isSelected {
        return isWindowKey
          ? Color(nsColor: .selectedContentBackgroundColor)
          : Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
      }
      if isHovered {
        return Color(nsColor: .controlAccentColor).opacity(0.10)
      }
      return Color(nsColor: NSColor.alternatingContentBackgroundColors[isAlternateRow ? 1 : 0])
    }
  }

  private enum PositionsTableRowPreviewData {
    static func make() -> [ValuedPosition] {
      let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
      let cba = Instrument.stock(ticker: "CBA.AX", exchange: "ASX", name: "CBA")
      let eth = Instrument.crypto(
        chainId: 1,
        contractAddress: nil,
        symbol: "ETH",
        name: "Ethereum",
        decimals: 18)
      let aud = Instrument.AUD
      return [
        ValuedPosition(
          instrument: bhp,
          quantity: 250,
          unitPrice: InstrumentAmount(quantity: 45.30, instrument: aud),
          costBasis: InstrumentAmount(quantity: 10_125, instrument: aud),
          value: InstrumentAmount(quantity: 11_325, instrument: aud)),
        ValuedPosition(
          instrument: cba,
          quantity: 80,
          unitPrice: InstrumentAmount(quantity: 120, instrument: aud),
          costBasis: InstrumentAmount(quantity: 9_000, instrument: aud),
          value: InstrumentAmount(quantity: 9_600, instrument: aud)),
        ValuedPosition(
          instrument: eth,
          quantity: 2.45,
          unitPrice: InstrumentAmount(quantity: 4_000, instrument: aud),
          costBasis: InstrumentAmount(quantity: 7_500, instrument: aud),
          value: InstrumentAmount(quantity: 9_800, instrument: aud)),
        ValuedPosition(
          instrument: aud,
          quantity: 2_480,
          unitPrice: nil,
          costBasis: nil,
          value: InstrumentAmount(quantity: 2_480, instrument: aud)),
      ]
    }

    /// State variants surfaced in the preview, paired with the row index
    /// in `make()`. Listed here so the preview body stays inside
    /// SwiftLint's `closure_body_length` threshold.
    struct Variant: Identifiable {
      let id: Int
      let rowIndex: Int
      let isSelected: Bool
      let isFocused: Bool
      let isAlternateRow: Bool
    }

    static let variants: [Variant] = [
      .init(id: 0, rowIndex: 0, isSelected: false, isFocused: false, isAlternateRow: false),
      .init(id: 1, rowIndex: 1, isSelected: false, isFocused: false, isAlternateRow: true),
      .init(id: 2, rowIndex: 2, isSelected: true, isFocused: false, isAlternateRow: false),
      .init(id: 3, rowIndex: 3, isSelected: false, isFocused: true, isAlternateRow: true),
    ]
  }

  #Preview("PositionsTableRow - states") {
    let rows = PositionsTableRowPreviewData.make()
    return Grid(
      alignment: .leadingFirstTextBaseline,
      horizontalSpacing: 16,
      verticalSpacing: 0
    ) {
      ForEach(PositionsTableRowPreviewData.variants) { variant in
        PositionsTableRow(
          row: rows[variant.rowIndex],
          isSelected: variant.isSelected,
          isFocused: variant.isFocused,
          isAlternateRow: variant.isAlternateRow,
          toggleSelection: {})
      }
    }
    .padding(.horizontal, 12)
    .frame(width: 720)
  }

#endif
