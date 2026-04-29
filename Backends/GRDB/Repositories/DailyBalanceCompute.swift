// Backends/GRDB/Repositories/DailyBalanceCompute.swift

import Foundation
import GRDB

/// Computes account-level daily cumulative balances from transaction
/// legs for `GRDBInvestmentRepository.fetchDailyBalances`. Lifted out
/// of the main repository file so the class body stays under the
/// SwiftLint `type_body_length` budget.
///
/// Returns one `AccountDailyBalance` per (calendar-day, instrument)
/// tuple — multi-instrument legacy investment accounts no longer
/// conflate quantities of different instruments under a single label
/// (issue #579). The consuming `InvestmentStore` aggregates these into
/// the host currency via `InstrumentConversionService`.
enum DailyBalanceCompute {
  /// One leg paired with its parent transaction's date — the unit of
  /// work fed to `aggregateByInstrument`. Replaces an inline 3-tuple
  /// (`large_tuple` SwiftLint violation).
  private struct LegEntry {
    let date: Date
    let instrumentId: String
    let quantity: Int64
  }

  /// One slot in the per-(instrument, day) running-balance table. Replaces
  /// an inline 3-tuple to satisfy the `large_tuple` SwiftLint rule.
  private struct DailyBalanceEntry {
    let date: Date
    let storageValue: Int64
    let instrumentId: String
  }

  /// Reads booked legs (excluding scheduled recurrences), looks up
  /// their dates, and accumulates a per-instrument running balance,
  /// returning one entry per (calendar-day, instrument) tuple.
  static func compute(
    database: Database,
    accountId: UUID,
    defaultInstrument: Instrument
  ) throws -> [AccountDailyBalance] {
    let bookedLegs = try fetchBookedLegs(database: database, accountId: accountId)
    let dateById = try fetchTransactionDates(
      database: database, transactionIds: bookedLegs.map(\.transactionId))
    let instrumentMap = try InstrumentRow.fetchInstrumentMap(database: database)

    let entries = sortedLegEntries(legs: bookedLegs, dateById: dateById)
    return aggregateByInstrument(
      entries: entries,
      instrumentMap: instrumentMap,
      defaultInstrument: defaultInstrument)
  }

  /// Fetches transaction legs for `accountId` and filters out those
  /// belonging to scheduled (recurring) parents — they have not yet
  /// been booked.
  private static func fetchBookedLegs(
    database: Database, accountId: UUID
  ) throws -> [TransactionLegRow] {
    let scheduledIds =
      try TransactionRow
      .filter(TransactionRow.Columns.recurPeriod != nil)
      .select(TransactionRow.Columns.id, as: UUID.self)
      .fetchAll(database)
    let scheduledIdSet = Set(scheduledIds)
    let legs =
      try TransactionLegRow
      .filter(TransactionLegRow.Columns.accountId == accountId)
      .fetchAll(database)
    return legs.filter { !scheduledIdSet.contains($0.transactionId) }
  }

  /// Returns a map from `transactionId` → `date` for the given set of
  /// transaction ids, used to enrich legs with their parent
  /// transaction's date.
  private static func fetchTransactionDates(
    database: Database, transactionIds: [UUID]
  ) throws -> [UUID: Date] {
    let txnIds = Set(transactionIds)
    let txnRows =
      try TransactionRow
      .filter(txnIds.contains(TransactionRow.Columns.id))
      .fetchAll(database)
    return Dictionary(uniqueKeysWithValues: txnRows.map { ($0.id, $0.date) })
  }

  /// Joins legs to their parent transaction date, drops legs whose
  /// parent could not be located, and sorts ascending by date so the
  /// per-instrument running balance is deterministic.
  private static func sortedLegEntries(
    legs: [TransactionLegRow], dateById: [UUID: Date]
  ) -> [LegEntry] {
    legs
      .compactMap { leg -> LegEntry? in
        guard let date = dateById[leg.transactionId] else { return nil }
        return LegEntry(
          date: date, instrumentId: leg.instrumentId, quantity: leg.quantity)
      }
      .sorted { $0.date < $1.date }
  }

  /// Walks the date-sorted leg entries and produces one
  /// `AccountDailyBalance` per (calendar-day, instrument) tuple, each
  /// labelled with the leg's resolved `Instrument`. Result is sorted
  /// ascending by date with deterministic instrument ordering within a
  /// day (by `Instrument.id`).
  private static func aggregateByInstrument(
    entries: [LegEntry],
    instrumentMap: [String: Instrument],
    defaultInstrument: Instrument
  ) -> [AccountDailyBalance] {
    var runningByInstrument: [String: Int64] = [:]
    // Per (instrument, day) → running storage value at end of that day.
    var dailyByKey: [String: DailyBalanceEntry] = [:]
    let calendar = Calendar.current

    for entry in entries {
      runningByInstrument[entry.instrumentId, default: 0] += entry.quantity
      let dayKey = calendar.startOfDay(for: entry.date)
      let key = "\(entry.instrumentId)|\(dayKey.timeIntervalSinceReferenceDate)"
      dailyByKey[key] = DailyBalanceEntry(
        date: dayKey,
        storageValue: runningByInstrument[entry.instrumentId] ?? 0,
        instrumentId: entry.instrumentId)
    }

    return
      dailyByKey
      .values
      .sorted { lhs, rhs in
        if lhs.date != rhs.date { return lhs.date < rhs.date }
        return lhs.instrumentId < rhs.instrumentId
      }
      .map { entry in
        let instrument = instrumentMap[entry.instrumentId] ?? defaultInstrument
        return AccountDailyBalance(
          date: entry.date,
          balance: InstrumentAmount(
            storageValue: entry.storageValue, instrument: instrument))
      }
  }
}
