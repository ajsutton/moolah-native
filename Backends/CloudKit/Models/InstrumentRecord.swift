import Foundation
import SwiftData

@Model
final class InstrumentRecord {
  @Attribute(.unique)
  var id: String = ""
  var kind: String = "fiatCurrency"
  var name: String = ""
  var decimals: Int = 2
  var ticker: String?
  var exchange: String?
  var chainId: Int?
  var contractAddress: String?

  init(
    id: String,
    kind: String,
    name: String,
    decimals: Int,
    ticker: String? = nil,
    exchange: String? = nil,
    chainId: Int? = nil,
    contractAddress: String? = nil
  ) {
    self.id = id
    self.kind = kind
    self.name = name
    self.decimals = decimals
    self.ticker = ticker
    self.exchange = exchange
    self.chainId = chainId
    self.contractAddress = contractAddress
  }

  func toDomain() -> Instrument {
    Instrument(
      id: id,
      kind: Instrument.Kind(rawValue: kind) ?? .fiatCurrency,
      name: name,
      decimals: decimals,
      ticker: ticker,
      exchange: exchange,
      chainId: chainId,
      contractAddress: contractAddress
    )
  }

  static func from(_ instrument: Instrument) -> InstrumentRecord {
    InstrumentRecord(
      id: instrument.id,
      kind: instrument.kind.rawValue,
      name: instrument.name,
      decimals: instrument.decimals,
      ticker: instrument.ticker,
      exchange: instrument.exchange,
      chainId: instrument.chainId,
      contractAddress: instrument.contractAddress
    )
  }
}
