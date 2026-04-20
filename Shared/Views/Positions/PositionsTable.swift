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

  var body: some View {
    Group {
      #if os(macOS)
        wideLayout
      #else
        if sizeClass == .regular {
          wideLayout
        } else {
          narrowLayout
        }
      #endif
    }
  }

  private var groups: [InstrumentGroup] {
    InstrumentGroup.from(input.positions)
  }

  // MARK: - Wide

  @ViewBuilder
  private var wideLayout: some View {
    let allRows = groups.flatMap(\.rows)
    Table(allRows, selection: rowSelectionBinding) {
      TableColumn("Instrument") { row in
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
      TableColumn("Qty") { row in
        Text(qtyString(for: row))
          .monospacedDigit()
      }
      TableColumn("Unit Price") { row in
        if let unit = row.unitPrice {
          Text(unit.formatted).monospacedDigit()
        } else {
          Text("—").foregroundStyle(.tertiary)
        }
      }
      TableColumn("Cost") { row in
        if let cost = row.costBasis {
          Text(cost.formatted).monospacedDigit()
        } else {
          Text("—").foregroundStyle(.tertiary)
        }
      }
      TableColumn("Value") { row in
        if let value = row.value {
          Text(value.formatted).monospacedDigit()
        } else {
          Text("—").foregroundStyle(.tertiary)
        }
      }
      TableColumn("Gain") { row in
        if let gain = row.gainLoss {
          Text(gainString(gain))
            .monospacedDigit()
            .foregroundStyle(gain.isNegative ? .red : .green)
        } else {
          Text("—").foregroundStyle(.tertiary)
        }
      }
    }
  }

  /// `Table` selects on `id` (which is `instrument.id`); we adapt that to
  /// our `Instrument?` selection binding.
  private var rowSelectionBinding: Binding<Set<String>> {
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

  // MARK: - Narrow

  @ViewBuilder
  private var narrowLayout: some View {
    List {
      ForEach(groups) { group in
        if input.showsGroupSubtotals {
          Section(group.title) {
            ForEach(group.rows) { row in
              PositionRow(row: row)
                .contentShape(Rectangle())
                .onTapGesture {
                  selection = (selection == row.instrument) ? nil : row.instrument
                }
                .background(selection == row.instrument ? Color.accentColor.opacity(0.12) : .clear)
            }
          }
        } else {
          ForEach(group.rows) { row in
            PositionRow(row: row)
              .contentShape(Rectangle())
              .onTapGesture {
                selection = (selection == row.instrument) ? nil : row.instrument
              }
              .background(selection == row.instrument ? Color.accentColor.opacity(0.12) : .clear)
          }
        }
      }
    }
    #if !os(macOS)
      .listStyle(.plain)
    #endif
  }

  // MARK: - Helpers

  private func qtyString(for row: ValuedPosition) -> String {
    switch row.instrument.kind {
    case .fiatCurrency:
      return InstrumentAmount(quantity: row.quantity, instrument: row.instrument).formatted
    case .stock:
      let formatter = NumberFormatter()
      formatter.numberStyle = .decimal
      formatter.maximumFractionDigits = row.instrument.decimals
      return formatter.string(from: row.quantity as NSDecimalNumber) ?? "\(row.quantity)"
    case .cryptoToken:
      let formatter = NumberFormatter()
      formatter.numberStyle = .decimal
      formatter.maximumFractionDigits = min(row.instrument.decimals, 8)
      let qty = formatter.string(from: row.quantity as NSDecimalNumber) ?? "\(row.quantity)"
      return "\(qty) \(row.instrument.displayLabel)"
    }
  }

  private func gainString(_ gain: InstrumentAmount) -> String {
    let sign = gain.quantity > 0 ? "+" : ""
    return "\(sign)\(gain.formatted)"
  }
}

/// Internal grouping helper — splits the rows into Stocks / Crypto / Cash
/// in spec order. Each group is empty if no row of that kind appears.
struct InstrumentGroup: Identifiable {
  enum Kind { case stocks, crypto, cash }
  let kind: Kind
  let rows: [ValuedPosition]
  var id: String {
    switch kind {
    case .stocks: return "stocks"
    case .crypto: return "crypto"
    case .cash: return "cash"
    }
  }
  var title: String {
    switch kind {
    case .stocks: return "Stocks"
    case .crypto: return "Crypto"
    case .cash: return "Cash"
    }
  }

  static func from(_ rows: [ValuedPosition]) -> [InstrumentGroup] {
    let stocks = rows.filter { $0.instrument.kind == .stock }
    let crypto = rows.filter { $0.instrument.kind == .cryptoToken }
    let cash = rows.filter { $0.instrument.kind == .fiatCurrency }
    return [
      .init(kind: .stocks, rows: stocks),
      .init(kind: .crypto, rows: crypto),
      .init(kind: .cash, rows: cash),
    ].filter { !$0.rows.isEmpty }
  }
}
