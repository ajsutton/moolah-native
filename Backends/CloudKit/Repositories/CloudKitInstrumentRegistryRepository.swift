import Foundation
import OSLog
import SwiftData

/// `@unchecked Sendable` because:
/// - `modelContainer` is `Sendable` (SwiftData's contract).
/// - Injected hooks are `@Sendable` closures.
/// - `subscribers` is confined to `@MainActor` for all reads and writes.
/// Matches the pattern used by `CloudKitAccountRepository` and peers.
final class CloudKitInstrumentRegistryRepository:
  InstrumentRegistryRepository, @unchecked Sendable
{
  let modelContainer: ModelContainer
  private let onRecordChanged: @Sendable (String) -> Void
  private let onRecordDeleted: @Sendable (String) -> Void
  private let logger = Logger(
    subsystem: "com.moolah.app", category: "InstrumentRegistry")

  @MainActor private var subscribers: [UUID: AsyncStream<Void>.Continuation] = [:]

  /// - Parameters:
  ///   - onRecordChanged: Invoked from whatever task context completes the
  ///     SwiftData write — do not assume `@MainActor`. Typically used to
  ///     queue CKSyncEngine saves, which are themselves thread-safe.
  ///   - onRecordDeleted: Invoked from whatever task context completes the
  ///     SwiftData write — do not assume `@MainActor`. Typically used to
  ///     queue CKSyncEngine deletes, which are themselves thread-safe.
  init(
    modelContainer: ModelContainer,
    onRecordChanged: @escaping @Sendable (String) -> Void = { _ in },
    onRecordDeleted: @escaping @Sendable (String) -> Void = { _ in }
  ) {
    self.modelContainer = modelContainer
    self.onRecordChanged = onRecordChanged
    self.onRecordDeleted = onRecordDeleted
  }

  // MARK: - Reads (background context)

  func all() async throws -> [Instrument] {
    let context = ModelContext(modelContainer)
    let descriptor = FetchDescriptor<InstrumentRecord>()
    let records = try context.fetch(descriptor)
    let stored = records.map { $0.toDomain() }
    let storedIds = Set(stored.map(\.id))
    let ambient =
      Locale.Currency.isoCurrencies
      .map(\.identifier)
      .map { Instrument.fiat(code: $0) }
      .filter { !storedIds.contains($0.id) }
    return stored + ambient
  }

  func allCryptoRegistrations() async throws -> [CryptoRegistration] {
    let context = ModelContext(modelContainer)
    let cryptoKind = Instrument.Kind.cryptoToken.rawValue
    let descriptor = FetchDescriptor<InstrumentRecord>(
      predicate: #Predicate { $0.kind == cryptoKind }
    )
    let rows = try context.fetch(descriptor)
    return rows.compactMap { row -> CryptoRegistration? in
      let hasMapping =
        row.coingeckoId != nil
        || row.cryptocompareSymbol != nil
        || row.binanceSymbol != nil
      guard hasMapping else { return nil }
      let mapping = CryptoProviderMapping(
        instrumentId: row.id,
        coingeckoId: row.coingeckoId,
        cryptocompareSymbol: row.cryptocompareSymbol,
        binanceSymbol: row.binanceSymbol
      )
      return CryptoRegistration(instrument: row.toDomain(), mapping: mapping)
    }
  }

  // MARK: - Writes (main context)

  func registerCrypto(
    _ instrument: Instrument, mapping: CryptoProviderMapping
  ) async throws {
    precondition(instrument.kind == .cryptoToken)
    try await MainActor.run {
      try upsertCrypto(instrument: instrument, mapping: mapping)
    }
    onRecordChanged(instrument.id)
    await notifySubscribers()
  }

  @MainActor
  private func upsertCrypto(
    instrument: Instrument, mapping: CryptoProviderMapping
  ) throws {
    let context = modelContainer.mainContext
    let id = instrument.id
    let descriptor = FetchDescriptor<InstrumentRecord>(
      predicate: #Predicate { $0.id == id }
    )
    if let existing = try context.fetch(descriptor).first {
      existing.kind = instrument.kind.rawValue
      existing.name = instrument.name
      existing.decimals = instrument.decimals
      existing.ticker = instrument.ticker
      existing.exchange = instrument.exchange
      existing.chainId = instrument.chainId
      existing.contractAddress = instrument.contractAddress
      existing.coingeckoId = mapping.coingeckoId
      existing.cryptocompareSymbol = mapping.cryptocompareSymbol
      existing.binanceSymbol = mapping.binanceSymbol
    } else {
      let row = InstrumentRecord(
        id: id,
        kind: instrument.kind.rawValue,
        name: instrument.name,
        decimals: instrument.decimals,
        ticker: instrument.ticker,
        exchange: instrument.exchange,
        chainId: instrument.chainId,
        contractAddress: instrument.contractAddress,
        coingeckoId: mapping.coingeckoId,
        cryptocompareSymbol: mapping.cryptocompareSymbol,
        binanceSymbol: mapping.binanceSymbol
      )
      context.insert(row)
    }
    try context.save()
  }

  func registerStock(_ instrument: Instrument) async throws {
    precondition(instrument.kind == .stock)
    try await MainActor.run {
      try upsertStock(instrument: instrument)
    }
    onRecordChanged(instrument.id)
    await notifySubscribers()
  }

  @MainActor
  private func upsertStock(instrument: Instrument) throws {
    let context = modelContainer.mainContext
    let id = instrument.id
    let descriptor = FetchDescriptor<InstrumentRecord>(
      predicate: #Predicate { $0.id == id }
    )
    if let existing = try context.fetch(descriptor).first {
      existing.kind = instrument.kind.rawValue
      existing.name = instrument.name
      existing.decimals = instrument.decimals
      existing.ticker = instrument.ticker
      existing.exchange = instrument.exchange
    } else {
      let row = InstrumentRecord(
        id: id,
        kind: instrument.kind.rawValue,
        name: instrument.name,
        decimals: instrument.decimals,
        ticker: instrument.ticker,
        exchange: instrument.exchange
      )
      context.insert(row)
    }
    try context.save()
  }

  func remove(id: String) async throws {
    let didDelete: Bool = try await MainActor.run {
      try deleteRecord(id: id)
    }
    guard didDelete else { return }
    onRecordDeleted(id)
    await notifySubscribers()
  }

  @MainActor
  private func deleteRecord(id: String) throws -> Bool {
    let context = modelContainer.mainContext
    let fiatKind = Instrument.Kind.fiatCurrency.rawValue
    let descriptor = FetchDescriptor<InstrumentRecord>(
      predicate: #Predicate { $0.id == id }
    )
    guard let existing = try context.fetch(descriptor).first else { return false }
    guard existing.kind != fiatKind else { return false }
    context.delete(existing)
    try context.save()
    return true
  }

  // MARK: - Change fan-out

  @MainActor
  func observeChanges() -> AsyncStream<Void> {
    let key = UUID()
    return AsyncStream { [weak self] continuation in
      guard let self else {
        continuation.finish()
        return
      }
      self.subscribers[key] = continuation
      continuation.onTermination = { @Sendable [weak self] _ in
        Task { @MainActor [weak self] in
          self?.subscribers.removeValue(forKey: key)
        }
      }
    }
  }

  @MainActor
  private func notifySubscribers() {
    for continuation in subscribers.values {
      continuation.yield()
    }
  }
}
