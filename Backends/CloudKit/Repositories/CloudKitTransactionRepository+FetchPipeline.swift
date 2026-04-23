// swiftlint:disable multiline_arguments

import Foundation
import SwiftData
import os

/// Synchronous (`@MainActor`) fetch pipeline for
/// `CloudKitTransactionRepository.fetch`. Broken out from the main file so
/// each stage (predicate query, post-filters, pagination, subtotal compute,
/// prior-balance conversion) stays under SwiftLint's body-length limits and
/// can be read in isolation.
extension CloudKitTransactionRepository {
  /// Returns every matching transaction without pagination. Runs the filter
  /// and the `TransactionRecord`-to-domain conversion exactly once, so bulk
  /// callers (profile export, migration) avoid the
  /// `O(pages × full-dataset-work)` blow-up that `fetch(filter:page:pageSize:)`
  /// triggers when invoked in a pagination loop.
  func fetchAll(filter: TransactionFilter) async throws -> [Transaction] {
    let signpostID = OSSignpostID(log: Signposts.repository)
    os_signpost(
      .begin, log: Signposts.repository, name: "TransactionRepo.fetchAll", signpostID: signpostID)
    defer {
      os_signpost(
        .end, log: Signposts.repository, name: "TransactionRepo.fetchAll", signpostID: signpostID)
    }
    return try await MainActor.run {
      let scheduled = filter.scheduled ?? false
      var filteredRecords = try loadAndFilter(
        filter: filter, scheduled: scheduled, signpostID: signpostID)
      filteredRecords.sort { lhs, rhs in
        if lhs.date != rhs.date { return lhs.date > rhs.date }
        return lhs.id < rhs.id
      }
      return try loadPageTransactions(filteredRecords[...], signpostID: signpostID)
    }
  }

  /// Synchronous portion of `fetch` — runs entirely on the main actor and
  /// returns the raw ingredients that the async caller needs (page
  /// transactions, per-instrument subtotals, target instrument). Conversion
  /// of subtotals to the target instrument happens outside this function.
  @MainActor
  func fetchPageOnMainActor(
    filter: TransactionFilter,
    page: Int,
    pageSize: Int,
    signpostID: OSSignpostID
  ) throws -> FetchResult {
    let scheduled = filter.scheduled ?? false
    var filteredRecords = try loadAndFilter(
      filter: filter, scheduled: scheduled, signpostID: signpostID)
    filteredRecords.sort { lhs, rhs in
      if lhs.date != rhs.date { return lhs.date > rhs.date }
      return lhs.id < rhs.id
    }

    let resolvedTarget = resolveTargetInstrument(for: filter.accountId)
    let offset = page * pageSize
    guard offset < filteredRecords.count else {
      return FetchResult(
        pageTransactions: [],
        subtotalsToConvert: [],
        resolvedTarget: resolvedTarget,
        hasAccountFilter: filter.accountId != nil,
        totalCount: filteredRecords.count,
        isEmpty: true)
    }
    let totalCount = filteredRecords.count
    let end = min(offset + pageSize, totalCount)
    let pageRecords = filteredRecords[offset..<end]

    let pageTransactions = try loadPageTransactions(pageRecords, signpostID: signpostID)
    let subtotalsToConvert: [SubtotalEntry]
    if let accountId = filter.accountId {
      subtotalsToConvert = try subtotalsAfterPage(
        accountId: accountId,
        records: filteredRecords,
        afterIndex: end,
        signpostID: signpostID)
    } else {
      subtotalsToConvert = []
    }

    return FetchResult(
      pageTransactions: pageTransactions,
      subtotalsToConvert: subtotalsToConvert,
      resolvedTarget: resolvedTarget,
      hasAccountFilter: filter.accountId != nil,
      totalCount: totalCount,
      isEmpty: false)
  }

  // MARK: - Filtering

  /// Runs the predicate query (with leg-backed filters) and every in-memory
  /// post-filter the server applies, returning the unsorted candidate
  /// `TransactionRecord`s for the page.
  @MainActor
  private func loadAndFilter(
    filter: TransactionFilter,
    scheduled: Bool,
    signpostID: OSSignpostID
  ) throws -> [TransactionRecord] {
    os_signpost(
      .begin, log: Signposts.repository, name: "fetch.predicateQuery", signpostID: signpostID)
    let recordsFetch = try fetchTransactionRecords(
      scheduled: scheduled, dateRange: filter.dateRange)
    var filteredRecords = recordsFetch.records
    if let accountId = filter.accountId {
      let allowedIds = try accountLegTransactionIds(for: accountId)
      filteredRecords = filteredRecords.filter { allowedIds.contains($0.id) }
    }
    os_signpost(
      .end, log: Signposts.repository, name: "fetch.predicateQuery", signpostID: signpostID)

    os_signpost(
      .begin, log: Signposts.repository, name: "fetch.postFilter", signpostID: signpostID)
    defer {
      os_signpost(
        .end, log: Signposts.repository, name: "fetch.postFilter", signpostID: signpostID)
    }
    filteredRecords = applyScheduledAndDate(
      filteredRecords, scheduled: scheduled, filter: filter, result: recordsFetch.result)
    filteredRecords = try applyLegFilters(filteredRecords, filter: filter)
    if let payee = filter.payee, !payee.isEmpty {
      let lowered = payee.lowercased()
      filteredRecords = filteredRecords.filter {
        ($0.payee?.lowercased().contains(lowered)) == true
      }
    }
    return filteredRecords
  }

  @MainActor
  private func applyScheduledAndDate(
    _ records: [TransactionRecord],
    scheduled: Bool,
    filter: TransactionFilter,
    result: DescriptorResult
  ) -> [TransactionRecord] {
    var filteredRecords = records
    if !result.pushedScheduled {
      filteredRecords = filteredRecords.filter {
        scheduled ? $0.recurPeriod != nil : $0.recurPeriod == nil
      }
    }
    if !result.pushedDateRange, let dateRange = filter.dateRange {
      let start = dateRange.lowerBound
      let end = dateRange.upperBound
      filteredRecords = filteredRecords.filter { $0.date >= start && $0.date <= end }
    }
    return filteredRecords
  }

  @MainActor
  private func applyLegFilters(
    _ records: [TransactionRecord], filter: TransactionFilter
  ) throws -> [TransactionRecord] {
    var filteredRecords = records
    if let earmarkId = filter.earmarkId {
      let ids = try transactionIdsForEarmark(earmarkId)
      filteredRecords = filteredRecords.filter { ids.contains($0.id) }
    }
    if !filter.categoryIds.isEmpty {
      filteredRecords = try filterByCategoryIds(filteredRecords, categoryIds: filter.categoryIds)
    }
    return filteredRecords
  }

  @MainActor
  private func accountLegTransactionIds(for accountId: UUID) throws -> Set<UUID> {
    let aid = accountId
    let legDescriptor = FetchDescriptor<TransactionLegRecord>(
      predicate: #Predicate { $0.accountId == aid })
    return Set(try context.fetch(legDescriptor).map(\.transactionId))
  }

  @MainActor
  private func transactionIdsForEarmark(_ earmarkId: UUID) throws -> Set<UUID> {
    let eid = earmarkId
    let descriptor = FetchDescriptor<TransactionLegRecord>(
      predicate: #Predicate { $0.earmarkId == eid })
    return Set(try context.fetch(descriptor).map(\.transactionId))
  }

  @MainActor
  private func filterByCategoryIds(
    _ records: [TransactionRecord], categoryIds: Set<UUID>
  ) throws -> [TransactionRecord] {
    let allLegs = try fetchAllLegRecords()
    let legsByTxnId = Dictionary(grouping: allLegs, by: \.transactionId)
    return records.filter { record in
      guard let legs = legsByTxnId[record.id] else { return false }
      return legs.contains { leg in
        guard let catId = leg.categoryId else { return false }
        return categoryIds.contains(catId)
      }
    }
  }

  @MainActor
  private func resolveTargetInstrument(for accountId: UUID?) -> Instrument {
    guard let accountId else { return self.instrument }
    return (try? accountInstrument(id: accountId)) ?? self.instrument
  }

  // MARK: - Page Materialization

  /// Bulk-fetches legs for the page once and returns the domain
  /// `Transaction`s with their legs attached. Replaces the old
  /// per-transaction `fetchLegs(for:)` loop that caused N+1 queries (#353).
  @MainActor
  private func loadPageTransactions(
    _ pageRecords: ArraySlice<TransactionRecord>, signpostID: OSSignpostID
  ) throws -> [Transaction] {
    os_signpost(.begin, log: Signposts.repository, name: "fetch.toDomain", signpostID: signpostID)
    defer {
      os_signpost(.end, log: Signposts.repository, name: "fetch.toDomain", signpostID: signpostID)
    }
    let legsByTxnId = try fetchLegs(for: pageRecords.map(\.id))
    return pageRecords.map { record in
      record.toDomain(legs: legsByTxnId[record.id] ?? [])
    }
  }

  // MARK: - Prior Balance

  /// Groups raw leg storage values by instrument for transactions that fall
  /// _after_ the current page, so a running-balance can be shown on the
  /// page view. Returns empty when the account has no activity after the
  /// page — the caller treats that the same as "no prior balance needed".
  @MainActor
  private func subtotalsAfterPage(
    accountId: UUID,
    records: [TransactionRecord],
    afterIndex: Int,
    signpostID: OSSignpostID
  ) throws -> [SubtotalEntry] {
    os_signpost(.begin, log: Signposts.balance, name: "fetch.priorBalance", signpostID: signpostID)
    defer {
      os_signpost(.end, log: Signposts.balance, name: "fetch.priorBalance", signpostID: signpostID)
    }
    let afterPageRecordIds = Set(records[afterIndex...].map(\.id))
    let aid = accountId
    let legDescriptor = FetchDescriptor<TransactionLegRecord>(
      predicate: #Predicate { $0.accountId == aid })
    let allAccountLegs = try context.fetch(legDescriptor)

    var subtotalsById: [String: Int64] = [:]
    for leg in allAccountLegs where afterPageRecordIds.contains(leg.transactionId) {
      subtotalsById[leg.instrumentId, default: 0] += leg.quantity
    }
    return try subtotalsById.map { instrumentId, storageValue in
      let instrument = try resolveInstrument(id: instrumentId)
      return SubtotalEntry(
        instrument: instrument,
        amount: InstrumentAmount(storageValue: storageValue, instrument: instrument))
    }
  }

  /// Converts the `FetchResult`'s per-instrument subtotals to a single
  /// priorBalance on the target instrument. Runs outside `MainActor.run`
  /// because the conversion service is async.
  nonisolated func resolvePriorBalance(
    _ fetchResult: FetchResult, signpostID: OSSignpostID
  ) async -> InstrumentAmount? {
    if fetchResult.isEmpty || !fetchResult.hasAccountFilter {
      return InstrumentAmount.zero(instrument: fetchResult.resolvedTarget)
    }
    os_signpost(
      .begin, log: Signposts.balance,
      name: "fetch.priorBalance.convert", signpostID: signpostID)
    defer {
      os_signpost(
        .end, log: Signposts.balance,
        name: "fetch.priorBalance.convert", signpostID: signpostID)
    }
    return await convertSubtotals(
      fetchResult.subtotalsToConvert, to: fetchResult.resolvedTarget)
  }

  /// Converts a list of per-instrument subtotals to a single amount in
  /// `target` using today's exchange rate. Returns `nil` on any conversion
  /// failure and logs via `os.Logger` (Rule 11 of
  /// `guides/INSTRUMENT_CONVERSION_GUIDE.md`).
  nonisolated private func convertSubtotals(
    _ subtotals: [SubtotalEntry],
    to target: Instrument
  ) async -> InstrumentAmount? {
    var total = InstrumentAmount.zero(instrument: target)
    let today = Date()
    for entry in subtotals {
      if entry.instrument == target {
        total += entry.amount
        continue
      }
      do {
        let converted = try await conversionService.convertAmount(
          entry.amount, to: target, on: today)
        guard !Task.isCancelled else { return nil }
        total += converted
      } catch {
        logger.warning(
          "priorBalance conversion failed for \(entry.instrument.id, privacy: .public) -> \(target.id, privacy: .public): \(String(describing: error), privacy: .public)"
        )
        return nil
      }
    }
    return total
  }

  // MARK: - Predicate Push-Down Helpers

  /// Fetches TransactionRecords with scheduled and dateRange filters pushed into SwiftData predicates.
  @MainActor
  private func fetchTransactionRecords(
    scheduled: Bool,
    dateRange: ClosedRange<Date>?
  ) throws -> (records: [TransactionRecord], result: DescriptorResult) {
    let sortDescriptors = [SortDescriptor(\TransactionRecord.date, order: .reverse)]

    switch (scheduled, dateRange) {
    case (false, nil):
      return (
        try context.fetch(
          FetchDescriptor<TransactionRecord>(
            predicate: #Predicate { $0.recurPeriod == nil },
            sortBy: sortDescriptors
          )), DescriptorResult(pushedScheduled: true, pushedDateRange: false)
      )

    case (true, nil):
      return (
        try context.fetch(
          FetchDescriptor<TransactionRecord>(
            predicate: #Predicate { $0.recurPeriod != nil },
            sortBy: sortDescriptors
          )), DescriptorResult(pushedScheduled: true, pushedDateRange: false)
      )

    case (false, .some(let range)):
      let start = range.lowerBound
      let end = range.upperBound
      return (
        try context.fetch(
          FetchDescriptor<TransactionRecord>(
            predicate: #Predicate {
              $0.recurPeriod == nil && $0.date >= start && $0.date <= end
            },
            sortBy: sortDescriptors
          )), DescriptorResult(pushedScheduled: true, pushedDateRange: true)
      )

    case (true, .some(let range)):
      let start = range.lowerBound
      let end = range.upperBound
      return (
        try context.fetch(
          FetchDescriptor<TransactionRecord>(
            predicate: #Predicate {
              $0.recurPeriod != nil && $0.date >= start && $0.date <= end
            },
            sortBy: sortDescriptors
          )), DescriptorResult(pushedScheduled: true, pushedDateRange: true)
      )
    }
  }
}
