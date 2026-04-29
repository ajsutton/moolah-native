import Foundation
import SwiftData

@Model
final class InstrumentRecord {
  var id: String = ""
  var kind: String = "fiatCurrency"
  var name: String = ""
  var decimals: Int = 2
  var ticker: String?
  var exchange: String?
  var chainId: Int?
  var contractAddress: String?
  var coingeckoId: String?
  var cryptocompareSymbol: String?
  var binanceSymbol: String?
  var encodedSystemFields: Data?

  init(
    id: String,
    kind: String,
    name: String,
    decimals: Int,
    ticker: String? = nil,
    exchange: String? = nil,
    chainId: Int? = nil,
    contractAddress: String? = nil,
    coingeckoId: String? = nil,
    cryptocompareSymbol: String? = nil,
    binanceSymbol: String? = nil
  ) {
    self.id = id
    self.kind = kind
    self.name = name
    self.decimals = decimals
    self.ticker = ticker
    self.exchange = exchange
    self.chainId = chainId
    self.contractAddress = contractAddress
    self.coingeckoId = coingeckoId
    self.cryptocompareSymbol = cryptocompareSymbol
    self.binanceSymbol = binanceSymbol
  }

  /// Throws `BackendError.dataCorrupted` when `kind` carries a raw value
  /// the compiled `Instrument.Kind` enum doesn't recognise.
  func toDomain() throws -> Instrument {
    Instrument(
      id: id,
      kind: try Instrument.Kind.decoded(rawValue: kind, label: "Instrument.Kind"),
      name: name,
      decimals: decimals,
      ticker: ticker,
      exchange: exchange,
      chainId: chainId,
      contractAddress: contractAddress
    )
  }

  /// Builds a minimal `InstrumentRecord` from a domain `Instrument`.
  /// Provider-mapping fields (`coingeckoId`, `cryptocompareSymbol`, `binanceSymbol`)
  /// are intentionally not copied — they live on the persistence side only, and
  /// are populated via `InstrumentRegistryRepository.registerCrypto(_:mapping:)`
  /// when a user registers a crypto instrument with its mapping. Callers using
  /// `from(_:)` (e.g. `ensureInstrument`) produce rows without mappings, which
  /// is the correct behaviour for auto-insertion.
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
