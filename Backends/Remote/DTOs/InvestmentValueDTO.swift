import Foundation

struct InvestmentValueDTO: Codable {
  let date: String  // "yyyy-MM-dd"
  let value: Int  // Cents

  func toDomain(instrument: Instrument) -> InvestmentValue {
    let parsedDate = BackendDateFormatter.date(from: date) ?? Date()
    return InvestmentValue(
      date: parsedDate,
      value: InstrumentAmount(quantity: Decimal(value) / 100, instrument: instrument)
    )
  }

  struct ListWrapper: Codable {
    let values: [InvestmentValueDTO]
    let hasMore: Bool
  }
}
