import SwiftUI

#if os(macOS)

  /// One Grid row inside `PositionsTable.macOSGridLayout`. Owns its
  /// own hover state so SwiftUI's diffing keeps hover-only re-renders
  /// scoped to a single row. Reads `@Environment(\.controlActiveState)`
  /// so the selection background swaps between
  /// `selectedContentBackgroundColor` and
  /// `unemphasizedSelectedContentBackgroundColor` when the window loses
  /// key state (spec §1.2 — native `NSTableView` swaps these automatically
  /// but SwiftUI's `Color(nsColor:)` is static, so the swap is driven
  /// here).
  ///
  /// Accessibility shape: this view carries **no** per-cell or per-row
  /// accessibility config — the parent's
  /// `.accessibilityRepresentation { Table(...) }` (Task 5) replaces
  /// the Grid's entire accessibility tree with a native `Table`, which
  /// advertises the "Table" trait, column headers, and row navigation
  /// to VoiceOver out of the box.
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
      }
      .padding(.vertical, 6)
      .padding(.horizontal, 8)
      .background(
        Self.rowBackground(
          isSelected: isSelected,
          isHovered: isHovered,
          isFocused: controlActiveState == .key,
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

    // MARK: - Background (spec §1.2)

    /// Resolves the row background from AppKit semantic tokens —
    /// `selectedContentBackgroundColor` (key window), the
    /// `unemphasizedSelected…` variant (window not key),
    /// `controlAccentColor.opacity(0.10)` (hover —
    /// the one place opacity is permitted per spec §1.2 because AppKit
    /// has no single "row hover" semantic colour and 10% is the
    /// published `NSTableRowView` convention), and
    /// `alternatingContentBackgroundColors[0|1]` (zebra striping —
    /// system-resolved so Increase Contrast disables striping for free).
    static func rowBackground(
      isSelected: Bool,
      isHovered: Bool,
      isFocused: Bool,
      isAlternateRow: Bool
    ) -> Color {
      if isSelected {
        return isFocused
          ? Color(nsColor: .selectedContentBackgroundColor)
          : Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
      }
      if isHovered {
        return Color(nsColor: .controlAccentColor).opacity(0.10)
      }
      return Color(nsColor: NSColor.alternatingContentBackgroundColors[isAlternateRow ? 1 : 0])
    }
  }

#endif
