// Backends/GRDB/Records/InstrumentRow+Mapping.swift

import Foundation

extension InstrumentRow {
  /// The CloudKit recordType on the wire for this record. Frozen contract;
  /// existing iCloud zones reference this exact string regardless of how
  /// the local Swift type is named.
  static let recordType = "InstrumentRecord"

  /// Builds the canonical CloudKit `recordName` for an instrument id.
  /// Instruments are string-keyed; the recordName is the bare id with no
  /// `recordType|` prefix (mirrors `InstrumentRecord+CloudKit.swift`).
  static func recordName(for id: String) -> String { id }

  /// Builds a row from a domain `Instrument`. The provider-mapping fields
  /// are left nil here — they are only populated via
  /// `GRDBInstrumentRegistryRepository.registerCrypto(_:mapping:)` /
  /// `registerStock(_:)` (mirroring `InstrumentRecord.from(_:)` which
  /// also omits them).
  init(domain: Instrument) {
    self.id = domain.id
    self.recordName = Self.recordName(for: domain.id)
    self.kind = domain.kind.rawValue
    self.name = domain.name
    self.decimals = domain.decimals
    self.ticker = domain.ticker
    self.exchange = domain.exchange
    self.chainId = domain.chainId
    self.contractAddress = domain.contractAddress
    self.coingeckoId = nil
    self.cryptocompareSymbol = nil
    self.binanceSymbol = nil
    self.encodedSystemFields = nil
  }

  /// Domain projection. Provider-mapping fields are exposed via
  /// `cryptoMapping` for the registry's `allCryptoRegistrations()` path;
  /// the domain `Instrument` itself does not carry them.
  func toDomain() -> Instrument {
    Instrument(
      id: id,
      kind: Instrument.Kind(rawValue: kind) ?? .fiatCurrency,
      name: name,
      decimals: decimals,
      ticker: ticker,
      exchange: exchange,
      chainId: chainId,
      contractAddress: contractAddress)
  }

  /// `CryptoProviderMapping` reconstructed from the row's three provider
  /// columns. Returns `nil` when no mapping is recorded (matches the
  /// `hasMapping` guard in `CloudKitInstrumentRegistryRepository`).
  func cryptoMapping() -> CryptoProviderMapping? {
    let hasMapping =
      coingeckoId != nil
      || cryptocompareSymbol != nil
      || binanceSymbol != nil
    guard hasMapping else { return nil }
    return CryptoProviderMapping(
      instrumentId: id,
      coingeckoId: coingeckoId,
      cryptocompareSymbol: cryptocompareSymbol,
      binanceSymbol: binanceSymbol)
  }
}
