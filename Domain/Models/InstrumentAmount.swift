import Foundation

/// The universal scaling factor for storage: all quantities are stored as Int64 × 10^8.
private let storageScale: Decimal = 100_000_000

struct InstrumentAmount: Codable, Sendable, Hashable, Comparable {
  let quantity: Decimal
  let instrument: Instrument

  static func zero(instrument: Instrument) -> InstrumentAmount {
    InstrumentAmount(quantity: 0, instrument: instrument)
  }

  var decimalValue: Decimal { quantity }
  var doubleValue: Double { Double(truncating: quantity as NSDecimalNumber) }

  var isPositive: Bool { quantity > 0 }
  var isNegative: Bool { quantity < 0 }
  var isZero: Bool { quantity == 0 }

  // MARK: - Formatting

  var formatted: String {
    switch instrument.kind {
    case .fiatCurrency:
      return quantity.formatted(.currency(code: instrument.id))
    case .stock, .cryptoToken:
      let number = quantity.formatted(.number.precision(.fractionLength(0...instrument.decimals)))
      return "\(number) \(instrument.displaySymbol ?? instrument.name)"
    }
  }

  var formatNoSymbol: String {
    quantity.formatted(.number.precision(.fractionLength(instrument.decimals)))
  }

  // MARK: - Storage (Int64 scaled by 10^8)

  var storageValue: Int64 {
    let scaled = quantity * storageScale
    return Int64(truncating: scaled as NSDecimalNumber)
  }

  init(quantity: Decimal, instrument: Instrument) {
    self.quantity = quantity
    self.instrument = instrument
  }

  init(storageValue: Int64, instrument: Instrument) {
    self.quantity = Decimal(storageValue) / storageScale
    self.instrument = instrument
  }

  // MARK: - Arithmetic

  static func + (lhs: InstrumentAmount, rhs: InstrumentAmount) -> InstrumentAmount {
    precondition(
      lhs.instrument == rhs.instrument,
      "Cannot add amounts with different instruments: \(lhs.instrument.id) + \(rhs.instrument.id)"
    )
    return InstrumentAmount(quantity: lhs.quantity + rhs.quantity, instrument: lhs.instrument)
  }

  static func - (lhs: InstrumentAmount, rhs: InstrumentAmount) -> InstrumentAmount {
    precondition(
      lhs.instrument == rhs.instrument,
      "Cannot subtract amounts with different instruments: \(lhs.instrument.id) - \(rhs.instrument.id)"
    )
    return InstrumentAmount(quantity: lhs.quantity - rhs.quantity, instrument: lhs.instrument)
  }

  static prefix func - (amount: InstrumentAmount) -> InstrumentAmount {
    InstrumentAmount(quantity: -amount.quantity, instrument: amount.instrument)
  }

  static func += (lhs: inout InstrumentAmount, rhs: InstrumentAmount) {
    lhs = lhs + rhs
  }

  static func -= (lhs: inout InstrumentAmount, rhs: InstrumentAmount) {
    lhs = lhs - rhs
  }

  static func < (lhs: InstrumentAmount, rhs: InstrumentAmount) -> Bool {
    lhs.quantity < rhs.quantity
  }

  // MARK: - Parsing

  static func parseQuantity(from text: String, decimals: Int) -> Decimal? {
    let cleaned = text.replacingOccurrences(of: "[^0-9.]", with: "", options: .regularExpression)
    guard !cleaned.isEmpty,
      cleaned.filter({ $0 == "." }).count <= 1,
      let decimal = Decimal(string: cleaned)
    else { return nil }
    return decimal
  }
}
