import Foundation
import OSLog
import SwiftData
import os

final class CloudKitTransactionRepository: TransactionRepository, @unchecked Sendable {
  let modelContainer: ModelContainer
  let instrument: Instrument
  let conversionService: any InstrumentConversionService
  let logger = Logger(
    subsystem: "com.moolah.app", category: "CloudKitTransactionRepository")
  /// Receives `(recordType, id)` so legs and parent transactions tag their
  /// own CloudKit `recordName` correctly. The transaction repo emits both
  /// `TransactionRecord` (parent) and `TransactionLegRecord` (per leg) ids
  /// from the same mutation, so the callback must carry the type — see the
  /// regression in `RepositoryHookRecordTypeTests`.
  var onRecordChanged: (String, UUID) -> Void = { _, _ in }
  var onRecordDeleted: (String, UUID) -> Void = { _, _ in }
  var onInstrumentChanged: (String) -> Void = { _ in }

  init(
    modelContainer: ModelContainer,
    instrument: Instrument,
    conversionService: any InstrumentConversionService
  ) {
    self.modelContainer = modelContainer
    self.instrument = instrument
    self.conversionService = conversionService
  }

  @MainActor var context: ModelContext {
    modelContainer.mainContext
  }

  // MARK: - Instrument Cache

  @MainActor var instrumentCache: [String: Instrument] = [:]

  @MainActor
  func resolveInstrument(id: String) throws -> Instrument {
    if let cached = instrumentCache[id] { return cached }
    let iid = id
    let descriptor = FetchDescriptor<InstrumentRecord>(predicate: #Predicate { $0.id == iid })
    if let record = try context.fetch(descriptor).first {
      let instrument = record.toDomain()
      instrumentCache[id] = instrument
      return instrument
    }
    let instrument = Instrument.fiat(code: id)
    instrumentCache[id] = instrument
    return instrument
  }

  @MainActor
  func ensureInstrument(_ instrument: Instrument) throws {
    switch instrument.kind {
    case .fiatCurrency:
      // Fiat is ambient — synthesised from `Locale.Currency.isoCurrencies`
      // by the registry. No row is required.
      instrumentCache[instrument.id] = instrument
    case .stock:
      // Stock path intentionally unchanged in this plan. CSV imports do
      // not currently produce unmapped stock rows in the same way the
      // crypto path does, so tightening this without a clear motivating
      // failure risks regressing imports. See design plan §4.8.
      let iid = instrument.id
      let descriptor = FetchDescriptor<InstrumentRecord>(predicate: #Predicate { $0.id == iid })
      if try context.fetch(descriptor).isEmpty {
        context.insert(InstrumentRecord.from(instrument))
        onInstrumentChanged(instrument.id)
      }
      instrumentCache[instrument.id] = instrument
    case .cryptoToken:
      // A crypto write must reference an instrument the registry has seen
      // and assigned at least one provider mapping (CoinGecko, CryptoCompare,
      // or Binance). Auto-inserting an unmapped row here would defer the
      // failure to conversion time as `ConversionError.noProviderMapping`.
      // Routing the user through `InstrumentPickerStore.resolve(_:)` (or
      // the Add Token flow) is the contract; throwing here surfaces the
      // programmer error early.
      let iid = instrument.id
      let descriptor = FetchDescriptor<InstrumentRecord>(predicate: #Predicate { $0.id == iid })
      let existing = try context.fetch(descriptor).first
      let isMapped =
        existing?.coingeckoId != nil
        || existing?.cryptocompareSymbol != nil
        || existing?.binanceSymbol != nil
      guard isMapped else {
        throw UnmappedCryptoInstrumentError(instrumentId: instrument.id)
      }
      instrumentCache[instrument.id] = instrument
    }
  }

  /// Returns the instrument associated with the given account, falling back
  /// to the profile instrument if the account isn't found.
  @MainActor
  func accountInstrument(id: UUID) throws -> Instrument {
    let accountDescriptor = FetchDescriptor<AccountRecord>(predicate: #Predicate { $0.id == id })
    guard let record = try context.fetch(accountDescriptor).first else {
      return self.instrument
    }
    return try resolveInstrument(id: record.instrumentId)
  }

  // MARK: - Fetch

  func fetch(filter: TransactionFilter, page: Int, pageSize: Int) async throws -> TransactionPage {
    let signpostID = OSSignpostID(log: Signposts.repository)
    os_signpost(
      .begin, log: Signposts.repository, name: "TransactionRepo.fetch", signpostID: signpostID)
    defer {
      os_signpost(
        .end, log: Signposts.repository, name: "TransactionRepo.fetch", signpostID: signpostID)
    }
    let fetchResult = try await MainActor.run {
      try fetchPageOnMainActor(
        filter: filter, page: page, pageSize: pageSize, signpostID: signpostID)
    }
    let priorBalance = await resolvePriorBalance(fetchResult, signpostID: signpostID)
    return TransactionPage(
      transactions: fetchResult.pageTransactions,
      targetInstrument: fetchResult.resolvedTarget,
      priorBalance: priorBalance,
      totalCount: fetchResult.totalCount)
  }
}

// MARK: - Fetch Pipeline Support Types
//
// Shared across CloudKitTransactionRepository+FetchPipeline.swift and the
// class's public `fetch` entry point. Kept at file scope (not nested in the
// class) so the extension file can see them without a cross-file private
// widening; otherwise these types are purely internal to the fetch
// pipeline.

/// Per-instrument subtotal carried across the `MainActor`/async-conversion
/// boundary. Raw `Int64` storage is summed inside the MainActor/SwiftData
/// block (fast path — no per-leg `toDomain` / `Decimal` / conversion) and
/// then converted to the account's instrument outside `MainActor.run`.
struct SubtotalEntry: Sendable {
  let instrument: Instrument
  let amount: InstrumentAmount
}

/// Intermediate result returned from the `MainActor.run` block in
/// `fetch(filter:page:pageSize:)`. Conversion of per-instrument subtotals
/// happens on the caller's actor, so the MainActor block hands back the
/// raw ingredients rather than a fully-formed `TransactionPage`.
///
/// `subtotalsToConvert` is empty when there's no account filter — no
/// account-level running-balance is applicable and the caller short-circuits
/// to a zero prior balance. An account with no legs after the page produces
/// the same empty value, which is the correct semantic (running balance of
/// zero in the account's target instrument).
struct FetchResult: Sendable {
  let pageTransactions: [Transaction]
  let subtotalsToConvert: [SubtotalEntry]
  let resolvedTarget: Instrument
  /// Set when the caller supplied an account filter, so the prior-balance
  /// stage knows whether to compute a running balance or short-circuit.
  let hasAccountFilter: Bool
  let totalCount: Int?
  /// `true` when the requested page was past the end of the result set;
  /// `pageTransactions` is empty and no prior-balance computation is needed.
  let isEmpty: Bool
}

/// Tracks which filters were pushed into the SwiftData predicate so post-filters can skip them.
struct DescriptorResult: Sendable {
  let pushedScheduled: Bool
  let pushedDateRange: Bool
}

/// Snapshot of the (date, id) tuple used to order `TransactionRecord`s without
/// re-faulting the SwiftData persisted properties for every comparison. The
/// `offset` indexes back into the original record array so the sorted result
/// can be reconstructed. See `sortedByDateDescThenId` and #517.
struct RecordSortKey: Sendable {
  let date: Date
  let id: UUID
  let offset: Int
}
