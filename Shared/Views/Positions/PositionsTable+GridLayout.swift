import SwiftUI

#if os(macOS)

  /// macOS-only Grid rendering path for `PositionsTable`. Split out of the
  /// main file to keep `PositionsTable.swift` under SwiftLint's
  /// `file_length` / `type_body_length` thresholds; the `@State`
  /// properties driving this code path stay on the main type (Swift
  /// disallows stored properties in extensions).
  ///
  /// Spec: `plans/2026-05-13-scrolling-detail-headers-redesign.md` §1.
  extension PositionsTable {
    // MARK: - macOS Grid (spec §1)

    @ViewBuilder var macOSGridLayout: some View {
      let sortedRows = sort.sorted(groups.flatMap(\.rows))
      Grid(
        alignment: .leadingFirstTextBaseline,
        horizontalSpacing: 16,
        verticalSpacing: 0
      ) {
        headerRow
        Divider().gridCellColumns(6)
        ForEach(Array(sortedRows.enumerated()), id: \.element.id) { item in
          // Closure parameter tuple destructuring (`{ idx, row in }`)
          // was removed in Swift 4 (SE-0110); destructure inside the
          // body.
          let (idx, row) = (item.offset, item.element)
          PositionsTableRow(
            row: row,
            isSelected: selection?.id == row.id,
            isFocused: focusedRowIndex == idx && isPanelFocused,
            isAlternateRow: !idx.isMultiple(of: 2),
            toggleSelection: { toggleSelection(row.instrument) })
        }
      }
      .padding(.horizontal, 12)
      .dynamicTypeSize(.medium...(.xLarge))
      .focusable()
      .focused($isPanelFocused)
      .onChange(of: isPanelFocused) { _, focused in
        // On focus-gain seed the cursor at the top so Up/Down has a
        // starting point; on focus-loss clear it so the focus ring
        // disappears when the user Tabs away.
        if focused, focusedRowIndex == nil, !sortedRows.isEmpty {
          focusedRowIndex = 0
        } else if !focused {
          focusedRowIndex = nil
        }
      }
      .onKeyPress(.upArrow) {
        guard !sortedRows.isEmpty else { return .ignored }
        focusedRowIndex = max(0, (focusedRowIndex ?? 0) - 1)
        return .handled
      }
      .onKeyPress(.downArrow) {
        guard !sortedRows.isEmpty else { return .ignored }
        focusedRowIndex = min(sortedRows.count - 1, (focusedRowIndex ?? -1) + 1)
        return .handled
      }
      .onKeyPress(.space) {
        guard let index = focusedRowIndex, index < sortedRows.count else { return .ignored }
        toggleSelection(sortedRows[index].instrument)
        return .handled
      }
      .onKeyPress(.return) {
        guard let index = focusedRowIndex, index < sortedRows.count else { return .ignored }
        toggleSelection(sortedRows[index].instrument)
        return .handled
      }
      // Pair the visible Grid with a native `Table` for accessibility
      // (spec Risk #7 — implemented, not deferred). `.accessibilityRepresentation`
      // replaces the host view's accessibility tree with the
      // representation view's tree; the visual layer is untouched. So
      // mouse / keyboard interaction still goes to the Grid, while
      // VoiceOver navigates the Table — getting the native "Table"
      // trait, column headers, and row/column navigation that a bare
      // Grid cannot reproduce. The Table's `sortOrder:` binding
      // tunnels VoiceOver's sort gestures back into `PositionsSortState`.
      .accessibilityRepresentation {
        Table(sortedRows, selection: rowSelectionBinding, sortOrder: tableSortOrderBinding) {
          TableColumn("Instrument", value: \.instrument.name) { row in
            Text(accessibilityInstrumentText(for: row))
          }
          TableColumn("Qty", value: \.quantity) { row in
            Text(row.quantityCaption)
          }
          TableColumn("Unit Price", value: \.unitPriceQuantity) { row in
            Text(row.unitPrice?.formatted ?? "no price")
          }
          TableColumn("Cost", value: \.costBasisQuantity) { row in
            Text(row.costBasis?.formatted ?? "no cost")
          }
          TableColumn("Value", value: \.valueQuantity) { row in
            Text(row.value?.formatted ?? "no value")
          }
          TableColumn("Gain", value: \.gainQuantity) { row in
            Text(accessibilityGainText(for: row))
          }
        }
      }
    }

    private func toggleSelection(_ instrument: Instrument) {
      selection = (selection?.id == instrument.id) ? nil : instrument
    }

    // MARK: - Header row (visible Grid headers)

    @ViewBuilder private var headerRow: some View {
      GridRow {
        sortHeader("Instrument", column: .instrument, alignment: .leading)
        sortHeader("Qty", column: .quantity, alignment: .trailing)
        sortHeader("Unit Price", column: .unitPrice, alignment: .trailing)
        sortHeader("Cost", column: .costBasis, alignment: .trailing)
        sortHeader("Value", column: .value, alignment: .trailing)
        sortHeader("Gain", column: .gain, alignment: .trailing)
      }
      .padding(.vertical, 4)
      .padding(.horizontal, 8)
    }

    @ViewBuilder
    private func sortHeader(
      _ title: String, column: PositionsSortColumn, alignment: HorizontalAlignment
    ) -> some View {
      Button {
        sort.toggleSort(column)
      } label: {
        HStack(spacing: 4) {
          if alignment == .trailing { Spacer(minLength: 0) }
          Text(title)
          if sort.column == column {
            // Active-column chevron renders to the right of the title
            // per spec §1 — matches Finder/Mail/Calendar convention.
            Image(systemName: sort.direction == .ascending ? "chevron.up" : "chevron.down")
              .imageScale(.small)
              .accessibilityHidden(true)
          }
          if alignment == .leading { Spacer(minLength: 0) }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      // `.borderless` (not `.plain`) — FOCUS_GUIDE.md §1.1 lists
      // `.bordered` / `.borderless` as Space-activatable under Full
      // Keyboard Access; `.plain` has the long-standing Space-
      // activation gap. Positions-table headers MUST be Space-
      // activatable.
      .buttonStyle(.borderless)
      .gridColumnAlignment(alignment)
    }

    // MARK: - Accessibility representation bindings

    /// Sort-order binding bridging the panel's `PositionsSortState` to
    /// the Table representation's `[KeyPathComparator<ValuedPosition>]`.
    /// VoiceOver column-header sort gestures route here, are converted
    /// to a `PositionsSortColumn` + `PositionsSortDirection`, and update
    /// the visual Grid's sort chrome via the shared state.
    private var tableSortOrderBinding: Binding<[KeyPathComparator<ValuedPosition>]> {
      Binding(
        get: { [Self.comparator(for: sort)] },
        set: { newOrder in
          guard let first = newOrder.first else { return }
          if let derived = Self.sortState(from: first) {
            sort = derived
          }
        }
      )
    }

    /// Maps a `PositionsSortState` to a single `KeyPathComparator` for
    /// the Table representation. The six key paths correspond to the
    /// six visible columns and reuse the existing `unitPriceQuantity` /
    /// `costBasisQuantity` / `valueQuantity` / `gainQuantity`
    /// sortable-`Decimal` accessors on `ValuedPosition` so missing
    /// values (`nil`) sort as zero, identical to the iOS Table path.
    private static func comparator(for state: PositionsSortState) -> KeyPathComparator<
      ValuedPosition
    > {
      let order: SortOrder = state.direction == .ascending ? .forward : .reverse
      switch state.column {
      case .instrument: return KeyPathComparator(\ValuedPosition.instrument.name, order: order)
      case .quantity: return KeyPathComparator(\ValuedPosition.quantity, order: order)
      case .unitPrice: return KeyPathComparator(\ValuedPosition.unitPriceQuantity, order: order)
      case .costBasis: return KeyPathComparator(\ValuedPosition.costBasisQuantity, order: order)
      case .value: return KeyPathComparator(\ValuedPosition.valueQuantity, order: order)
      case .gain: return KeyPathComparator(\ValuedPosition.gainQuantity, order: order)
      }
    }

    /// Inverse of `comparator(for:)`. Returns `nil` only if the
    /// comparator's key path doesn't match one of the six expected
    /// columns — which can't happen for comparators we produce, but is
    /// nominally possible if SwiftUI ever invents a new comparator
    /// shape from a different code path. Falls back to leaving sort
    /// state untouched in that case.
    private static func sortState(
      from comparator: KeyPathComparator<ValuedPosition>
    ) -> PositionsSortState? {
      let direction: PositionsSortDirection =
        comparator.order == .forward ? .ascending : .descending
      let column: PositionsSortColumn? = {
        switch comparator.keyPath {
        case \ValuedPosition.instrument.name: return .instrument
        case \ValuedPosition.quantity: return .quantity
        case \ValuedPosition.unitPriceQuantity: return .unitPrice
        case \ValuedPosition.costBasisQuantity: return .costBasis
        case \ValuedPosition.valueQuantity: return .value
        case \ValuedPosition.gainQuantity: return .gain
        default: return nil
        }
      }()
      guard let column else { return nil }
      return PositionsSortState(column: column, direction: direction)
    }

    // MARK: - Accessibility cell text

    private func accessibilityInstrumentText(for row: ValuedPosition) -> String {
      if let exchange = row.instrument.exchange {
        return "\(row.instrument.name), \(exchange)"
      }
      return row.instrument.name
    }

    /// Delegates to `gainAccessibilityLabel(gain:percent:)` on the main
    /// type to keep one source of truth for the gain phrase. Preserves
    /// the explicit "no gain or loss" fallback for the Table
    /// representation when the row has no gain/loss data.
    private func accessibilityGainText(for row: ValuedPosition) -> String {
      guard let gain = row.gainLoss else { return "no gain or loss" }
      return gainAccessibilityLabel(gain: gain, percent: row.gainLossPercent)
    }
  }

#endif
