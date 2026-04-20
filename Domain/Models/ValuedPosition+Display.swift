import Foundation

extension ValuedPosition {
  /// Human-friendly quantity string per instrument kind. Used by both
  /// `PositionRow` (narrow layout) and `PositionsTable` (wide layout).
  ///
  /// - `.fiatCurrency` → currency-formatted (e.g. "$1,520.00").
  /// - `.stock` → decimal with up to `instrument.decimals` places, no suffix.
  /// - `.cryptoToken` → decimal (capped at 8 places) + display label
  ///   (e.g. "2.45 ETH").
  ///
  /// Note: the wide layout omits "shares" suffix on stock because the
  /// column header is already labelled "Qty"; the narrow layout adds
  /// "shares" because the secondary line has no other context. Callers
  /// pick one — see `quantityCaption` for the suffix-bearing variant.
  var quantityFormatted: String {
    switch instrument.kind {
    case .fiatCurrency:
      return InstrumentAmount(quantity: quantity, instrument: instrument).formatted
    case .stock:
      let formatter = NumberFormatter()
      formatter.numberStyle = .decimal
      formatter.minimumFractionDigits = 0
      formatter.maximumFractionDigits = instrument.decimals
      return formatter.string(from: quantity as NSDecimalNumber) ?? "\(quantity)"
    case .cryptoToken:
      let formatter = NumberFormatter()
      formatter.numberStyle = .decimal
      formatter.minimumFractionDigits = 0
      formatter.maximumFractionDigits = min(instrument.decimals, 8)
      let qty = formatter.string(from: quantity as NSDecimalNumber) ?? "\(quantity)"
      return "\(qty) \(instrument.displayLabel)"
    }
  }

  /// Caption-style quantity suitable for the secondary line of a row in the
  /// narrow `PositionsTable` layout. Adds "shares" suffix for stocks; same
  /// as `quantityFormatted` otherwise.
  var quantityCaption: String {
    switch instrument.kind {
    case .stock:
      return "\(quantityFormatted) shares"
    case .fiatCurrency, .cryptoToken:
      return quantityFormatted
    }
  }
}

extension InstrumentAmount {
  /// Signed-amount string with explicit `+` prefix for positive values
  /// (negative values keep their natural `-` from `formatted`). Zero shows
  /// no prefix. Used for gain/loss display.
  var signedFormatted: String {
    let sign = quantity > 0 ? "+" : ""
    return "\(sign)\(formatted)"
  }
}

// MARK: - Sortable accessors

extension ValuedPosition {
  /// Non-optional `Decimal` view of `unitPrice` for sortable Table columns.
  /// Missing values sort as zero — paired with the `—` placeholder rendered
  /// in the cell, this groups failed/unknown rows together at one end.
  var unitPriceQuantity: Decimal { unitPrice?.quantity ?? 0 }

  /// Non-optional `Decimal` view of `costBasis` for sortable Table columns.
  /// Missing values sort as zero (see `unitPriceQuantity`).
  var costBasisQuantity: Decimal { costBasis?.quantity ?? 0 }

  /// Non-optional `Decimal` view of `value` for sortable Table columns.
  /// Missing values sort as zero (see `unitPriceQuantity`).
  var valueQuantity: Decimal { value?.quantity ?? 0 }

  /// Non-optional `Decimal` view of `gainLoss` for sortable Table columns.
  /// Missing values sort as zero (see `unitPriceQuantity`).
  var gainQuantity: Decimal { gainLoss?.quantity ?? 0 }
}
