import Foundation
import SwiftData
import os

final class CloudKitTransactionRepository: TransactionRepository, @unchecked Sendable {
  private let modelContainer: ModelContainer
  private let currency: Currency
  var onRecordChanged: (UUID) -> Void = { _ in }
  var onRecordDeleted: (UUID) -> Void = { _ in }

  init(modelContainer: ModelContainer, currency: Currency) {
    self.modelContainer = modelContainer
    self.currency = currency
  }

  @MainActor
  private var context: ModelContext {
    modelContainer.mainContext
  }

  func fetch(filter: TransactionFilter, page: Int, pageSize: Int) async throws -> TransactionPage {
    let signpostID = OSSignpostID(log: Signposts.repository)
    os_signpost(
      .begin, log: Signposts.repository, name: "TransactionRepo.fetch", signpostID: signpostID)
    defer {
      os_signpost(
        .end, log: Signposts.repository, name: "TransactionRepo.fetch", signpostID: signpostID)
    }
    return try await MainActor.run {
      // Match moolah-server: when scheduled is not explicitly requested, exclude scheduled
      // transactions. The server always adds `AND recur_period IS NULL` unless scheduled=true.
      let scheduled = filter.scheduled ?? false

      // Fast path: page 0 with simple accountId filter and cachedBalance available.
      // Computes priorBalance algebraically from cachedBalance instead of loading all records.
      if page == 0,
        !scheduled,
        let filterAccountId = filter.accountId,
        filter.categoryIds == nil,
        filter.payee == nil,
        filter.dateRange == nil,
        filter.earmarkId == nil
      {
        let accountDescriptor = FetchDescriptor<AccountRecord>(
          predicate: #Predicate { $0.id == filterAccountId }
        )
        if let account = try context.fetch(accountDescriptor).first,
          let cachedBalance = account.cachedBalance
        {
          return try fetchFastPath(
            accountId: filterAccountId,
            cachedBalance: cachedBalance,
            pageSize: pageSize,
            signpostID: signpostID
          )
        }
      }

      // --- Full fetch path (complex filters, later pages, or no cached balance) ---
      os_signpost(
        .begin, log: Signposts.repository, name: "fetch.predicateQuery", signpostID: signpostID)
      let primaryRecords: [TransactionRecord]
      let secondaryRecords: [TransactionRecord]

      // For accountId filter, we need two queries (accountId match + toAccountId match)
      // because OR across optional fields is unreliable in #Predicate.
      if let filterAccountId = filter.accountId {
        primaryRecords = try fetchRecords(
          accountId: filterAccountId,
          accountIdField: .primary,
          scheduled: scheduled,
          dateRange: filter.dateRange,
          earmarkId: filter.earmarkId
        )
        secondaryRecords = try fetchRecords(
          accountId: filterAccountId,
          accountIdField: .toAccount,
          scheduled: scheduled,
          dateRange: filter.dateRange,
          earmarkId: filter.earmarkId
        )
      } else {
        primaryRecords = try fetchRecords(
          accountId: nil,
          accountIdField: .none,
          scheduled: scheduled,
          dateRange: filter.dateRange,
          earmarkId: filter.earmarkId
        )
        secondaryRecords = []
      }

      // Merge and deduplicate (secondary query may overlap with primary)
      let mergedRecords: [TransactionRecord]
      if secondaryRecords.isEmpty {
        mergedRecords = primaryRecords
      } else {
        var seen = Set(primaryRecords.map(\.id))
        var combined = primaryRecords
        for record in secondaryRecords {
          if seen.insert(record.id).inserted {
            combined.append(record)
          }
        }
        mergedRecords = combined
      }
      os_signpost(
        .end, log: Signposts.repository, name: "fetch.predicateQuery", signpostID: signpostID)

      // --- In-memory post-filters ---
      // categoryIds and payee can never be pushed into #Predicate, so always apply here.
      // scheduled, dateRange, and earmarkId are pushed down for common combinations,
      // but we re-apply them here as a safety net for fallback cases. When the predicate
      // already filtered these, the in-memory pass is a no-op (nothing to remove).
      os_signpost(
        .begin, log: Signposts.repository, name: "fetch.postFilter", signpostID: signpostID)
      var filteredRecords = mergedRecords

      if scheduled {
        filteredRecords = filteredRecords.filter { $0.recurPeriod != nil }
      } else {
        filteredRecords = filteredRecords.filter { $0.recurPeriod == nil }
      }
      if let dateRange = filter.dateRange {
        let start = dateRange.lowerBound
        let end = dateRange.upperBound
        filteredRecords = filteredRecords.filter { $0.date >= start && $0.date <= end }
      }
      if let earmarkId = filter.earmarkId {
        filteredRecords = filteredRecords.filter { $0.earmarkId == earmarkId }
      }
      if let categoryIds = filter.categoryIds, !categoryIds.isEmpty {
        filteredRecords = filteredRecords.filter { record in
          guard let categoryId = record.categoryId else { return false }
          return categoryIds.contains(categoryId)
        }
      }
      if let payee = filter.payee, !payee.isEmpty {
        let lowered = payee.lowercased()
        filteredRecords = filteredRecords.filter { record in
          guard let recordPayee = record.payee else { return false }
          return recordPayee.lowercased().contains(lowered)
        }
      }
      os_signpost(.end, log: Signposts.repository, name: "fetch.postFilter", signpostID: signpostID)

      // --- Sort by date DESC, then id for stable ordering (matches server) ---
      os_signpost(.begin, log: Signposts.repository, name: "fetch.sort", signpostID: signpostID)
      filteredRecords.sort { a, b in
        if a.date != b.date { return a.date > b.date }
        return a.id < b.id
      }
      os_signpost(.end, log: Signposts.repository, name: "fetch.sort", signpostID: signpostID)

      // --- Paginate ---
      let offset = page * pageSize
      guard offset < filteredRecords.count else {
        return TransactionPage(
          transactions: [], priorBalance: MonetaryAmount(cents: 0, currency: self.currency),
          totalCount: filteredRecords.count)
      }
      let totalCount = filteredRecords.count
      let end = min(offset + pageSize, totalCount)
      let pageRecords = filteredRecords[offset..<end]

      // Convert only the page slice to domain objects (avoid toDomain() on entire dataset)
      os_signpost(.begin, log: Signposts.repository, name: "fetch.toDomain", signpostID: signpostID)
      let pageTransactions = pageRecords.map { $0.toDomain() }
      os_signpost(.end, log: Signposts.repository, name: "fetch.toDomain", signpostID: signpostID)

      // priorBalance = sum of adjusted amounts for all records after the current page.
      // Matches moolah-server: SUM(IF(to_account_id = ?, -amount, amount))
      // Records matched via toAccountId have their amount negated.
      os_signpost(
        .begin, log: Signposts.balance, name: "fetch.priorBalance", signpostID: signpostID)
      let filterAccountId = filter.accountId
      let priorBalanceCents = filteredRecords[end...].reduce(0) { sum, record in
        if let filterAccountId, record.accountId != filterAccountId {
          return sum - record.amount
        }
        return sum + record.amount
      }
      let priorBalance = MonetaryAmount(cents: priorBalanceCents, currency: self.currency)
      os_signpost(.end, log: Signposts.balance, name: "fetch.priorBalance", signpostID: signpostID)

      return TransactionPage(
        transactions: pageTransactions, priorBalance: priorBalance, totalCount: totalCount)
    }
  }

  // MARK: - Fast Path

  /// Optimized fetch for page 0 with a simple accountId filter and non-scheduled transactions.
  /// Instead of loading all ~14k records to sort/paginate/sum, loads only ~60 records:
  /// - All secondary (toAccount) records (typically very few transfers to a given account)
  /// - Top pageSize primary records via SwiftData fetchLimit
  /// Computes priorBalance as: cachedBalance - headAdjustedSum, where headAdjustedSum
  /// negates amounts for toAccountId matches (matching moolah-server sign convention).
  @MainActor
  private func fetchFastPath(
    accountId: UUID,
    cachedBalance: Int,
    pageSize: Int,
    signpostID: OSSignpostID
  ) throws -> TransactionPage {
    os_signpost(
      .begin, log: Signposts.repository, name: "fetch.fastPath", signpostID: signpostID)
    defer {
      os_signpost(
        .end, log: Signposts.repository, name: "fetch.fastPath", signpostID: signpostID)
    }

    // 1. Fetch ALL secondary records (transfers TO this account, non-scheduled).
    //    Typically very few — e.g., ~9 for the busiest account in a 37k dataset.
    let secondaryDescriptor = FetchDescriptor<TransactionRecord>(
      predicate: #Predicate { $0.toAccountId == accountId && $0.recurPeriod == nil },
      sortBy: [SortDescriptor(\TransactionRecord.date, order: .reverse)]
    )
    let secondaryRecords = try context.fetch(secondaryDescriptor)

    // 2. Fetch top pageSize primary records (SwiftData pushes sort+limit to SQLite).
    var primaryDescriptor = FetchDescriptor<TransactionRecord>(
      predicate: #Predicate { $0.accountId == accountId && $0.recurPeriod == nil },
      sortBy: [SortDescriptor(\TransactionRecord.date, order: .reverse)]
    )
    primaryDescriptor.fetchLimit = pageSize
    let primaryRecords = try context.fetch(primaryDescriptor)

    // 3. Merge, deduplicate, and sort the small combined set.
    var seen = Set(primaryRecords.map(\.id))
    var merged = primaryRecords
    for record in secondaryRecords {
      if seen.insert(record.id).inserted {
        merged.append(record)
      }
    }
    merged.sort { a, b in
      if a.date != b.date { return a.date > b.date }
      return a.id < b.id
    }

    // 4. Page records = first pageSize of the merged set.
    let end = min(pageSize, merged.count)
    let pageRecords = merged[0..<end]

    os_signpost(
      .begin, log: Signposts.repository, name: "fetch.toDomain", signpostID: signpostID)
    let pageTransactions = pageRecords.map { $0.toDomain() }
    os_signpost(.end, log: Signposts.repository, name: "fetch.toDomain", signpostID: signpostID)

    // 5. totalCount via fetchCount (O(1) SQL COUNT per query).
    let primaryCount = try context.fetchCount(
      FetchDescriptor<TransactionRecord>(
        predicate: #Predicate { $0.accountId == accountId && $0.recurPeriod == nil }
      ))
    let totalCount = primaryCount + secondaryRecords.count

    // 6. Compute priorBalance algebraically.
    //    cachedBalance = Σ(amount | accountId=A) - Σ(amount | toAccountId=A) for non-scheduled
    //    This matches the server's SUM(IF(to_account_id=?, -amount, amount)).
    //    priorBalance  = cachedBalance - headAdjustedSum
    //    headAdjustedSum negates amounts for records matched via toAccountId.
    os_signpost(
      .begin, log: Signposts.balance, name: "fetch.priorBalance", signpostID: signpostID)
    let secondaryIds = Set(secondaryRecords.map(\.id))
    let headAdjustedSum = pageRecords.reduce(0) { sum, record in
      if secondaryIds.contains(record.id) {
        return sum - record.amount
      }
      return sum + record.amount
    }
    let priorBalanceCents = cachedBalance - headAdjustedSum
    let priorBalance = MonetaryAmount(cents: priorBalanceCents, currency: self.currency)
    os_signpost(.end, log: Signposts.balance, name: "fetch.priorBalance", signpostID: signpostID)

    return TransactionPage(
      transactions: pageTransactions, priorBalance: priorBalance, totalCount: totalCount)
  }

  // MARK: - Predicate Push-Down Helpers

  private enum AccountIdField {
    case primary  // Match on accountId
    case toAccount  // Match on toAccountId
    case none  // No account filter
  }

  /// Fetches TransactionRecords with as many filters pushed into SwiftData predicates as possible.
  /// Since `#Predicate` is a macro requiring static expressions, we branch on which filters are set.
  @MainActor
  private func fetchRecords(
    accountId: UUID?,
    accountIdField: AccountIdField,
    scheduled: Bool?,
    dateRange: ClosedRange<Date>?,
    earmarkId: UUID?
  ) throws -> [TransactionRecord] {
    let descriptor = buildDescriptor(
      accountId: accountId,
      accountIdField: accountIdField,
      scheduled: scheduled,
      dateRange: dateRange,
      earmarkId: earmarkId
    )
    return try context.fetch(descriptor)
  }

  /// Builds a FetchDescriptor with the appropriate predicate based on which filters are active.
  /// We use a pragmatic approach: branch on accountId, scheduled, dateRange, and earmarkId
  /// combinations. To avoid 2^4 = 16 branches, we handle the most common combinations and fall
  /// back to fewer pushed-down filters for rare combinations.
  @MainActor
  private func buildDescriptor(
    accountId: UUID?,
    accountIdField: AccountIdField,
    scheduled: Bool?,
    dateRange: ClosedRange<Date>?,
    earmarkId: UUID?
  ) -> FetchDescriptor<TransactionRecord> {
    let sortDescriptors = [SortDescriptor(\TransactionRecord.date, order: .reverse)]

    // Helper to determine if scheduled filter means "is scheduled" or "not scheduled"
    let isScheduled = scheduled == true
    let isNotScheduled = scheduled == false

    // Branch based on which filters are set, focusing on the most common paths.
    // Account + scheduled is the most common combination (transaction list for an account).

    switch (accountIdField, scheduled, dateRange, earmarkId) {

    // --- No account filter ---
    case (.none, nil, nil, nil):
      let d = FetchDescriptor<TransactionRecord>(
        sortBy: sortDescriptors
      )
      return d

    case (.none, .some(_), nil, nil) where isScheduled:
      let d = FetchDescriptor<TransactionRecord>(
        predicate: #Predicate { $0.recurPeriod != nil },
        sortBy: sortDescriptors
      )
      return d

    case (.none, .some(_), nil, nil) where isNotScheduled:
      let d = FetchDescriptor<TransactionRecord>(
        predicate: #Predicate { $0.recurPeriod == nil },
        sortBy: sortDescriptors
      )
      return d

    case (.none, nil, .some(let range), nil):
      let start = range.lowerBound
      let end = range.upperBound
      let d = FetchDescriptor<TransactionRecord>(
        predicate: #Predicate { $0.date >= start && $0.date <= end },
        sortBy: sortDescriptors
      )
      return d

    case (.none, nil, nil, .some(let eid)):
      let d = FetchDescriptor<TransactionRecord>(
        predicate: #Predicate { $0.earmarkId == eid },
        sortBy: sortDescriptors
      )
      return d

    case (.none, .some(_), .some(let range), nil) where isNotScheduled:
      let start = range.lowerBound
      let end = range.upperBound
      let d = FetchDescriptor<TransactionRecord>(
        predicate: #Predicate {
          $0.recurPeriod == nil && $0.date >= start && $0.date <= end
        },
        sortBy: sortDescriptors
      )
      return d

    case (.none, .some(_), .some(let range), nil) where isScheduled:
      let start = range.lowerBound
      let end = range.upperBound
      let d = FetchDescriptor<TransactionRecord>(
        predicate: #Predicate {
          $0.recurPeriod != nil && $0.date >= start && $0.date <= end
        },
        sortBy: sortDescriptors
      )
      return d

    // --- Primary account filter ---
    case (.primary, nil, nil, nil):
      let aid = accountId!
      let d = FetchDescriptor<TransactionRecord>(
        predicate: #Predicate { $0.accountId == aid },
        sortBy: sortDescriptors
      )
      return d

    case (.primary, .some(_), nil, nil) where isNotScheduled:
      let aid = accountId!
      let d = FetchDescriptor<TransactionRecord>(
        predicate: #Predicate {
          $0.accountId == aid && $0.recurPeriod == nil
        },
        sortBy: sortDescriptors
      )
      return d

    case (.primary, .some(_), nil, nil) where isScheduled:
      let aid = accountId!
      let d = FetchDescriptor<TransactionRecord>(
        predicate: #Predicate {
          $0.accountId == aid && $0.recurPeriod != nil
        },
        sortBy: sortDescriptors
      )
      return d

    case (.primary, nil, .some(let range), nil):
      let aid = accountId!
      let start = range.lowerBound
      let end = range.upperBound
      let d = FetchDescriptor<TransactionRecord>(
        predicate: #Predicate {
          $0.accountId == aid && $0.date >= start && $0.date <= end
        },
        sortBy: sortDescriptors
      )
      return d

    case (.primary, nil, nil, .some(let eid)):
      let aid = accountId!
      let d = FetchDescriptor<TransactionRecord>(
        predicate: #Predicate {
          $0.accountId == aid && $0.earmarkId == eid
        },
        sortBy: sortDescriptors
      )
      return d

    case (.primary, .some(_), .some(let range), nil) where isNotScheduled:
      let aid = accountId!
      let start = range.lowerBound
      let end = range.upperBound
      let d = FetchDescriptor<TransactionRecord>(
        predicate: #Predicate {
          $0.accountId == aid && $0.recurPeriod == nil && $0.date >= start && $0.date <= end
        },
        sortBy: sortDescriptors
      )
      return d

    case (.primary, .some(_), .some(let range), nil) where isScheduled:
      let aid = accountId!
      let start = range.lowerBound
      let end = range.upperBound
      let d = FetchDescriptor<TransactionRecord>(
        predicate: #Predicate {
          $0.accountId == aid && $0.recurPeriod != nil && $0.date >= start && $0.date <= end
        },
        sortBy: sortDescriptors
      )
      return d

    // --- toAccount filter ---
    case (.toAccount, nil, nil, nil):
      let aid = accountId!
      let d = FetchDescriptor<TransactionRecord>(
        predicate: #Predicate { $0.toAccountId == aid },
        sortBy: sortDescriptors
      )
      return d

    case (.toAccount, .some(_), nil, nil) where isNotScheduled:
      let aid = accountId!
      let d = FetchDescriptor<TransactionRecord>(
        predicate: #Predicate {
          $0.toAccountId == aid && $0.recurPeriod == nil
        },
        sortBy: sortDescriptors
      )
      return d

    case (.toAccount, .some(_), nil, nil) where isScheduled:
      let aid = accountId!
      let d = FetchDescriptor<TransactionRecord>(
        predicate: #Predicate {
          $0.toAccountId == aid && $0.recurPeriod != nil
        },
        sortBy: sortDescriptors
      )
      return d

    case (.toAccount, nil, .some(let range), nil):
      let aid = accountId!
      let start = range.lowerBound
      let end = range.upperBound
      let d = FetchDescriptor<TransactionRecord>(
        predicate: #Predicate {
          $0.toAccountId == aid && $0.date >= start && $0.date <= end
        },
        sortBy: sortDescriptors
      )
      return d

    case (.toAccount, nil, nil, .some(let eid)):
      let aid = accountId!
      let d = FetchDescriptor<TransactionRecord>(
        predicate: #Predicate {
          $0.toAccountId == aid && $0.earmarkId == eid
        },
        sortBy: sortDescriptors
      )
      return d

    case (.toAccount, .some(_), .some(let range), nil) where isNotScheduled:
      let aid = accountId!
      let start = range.lowerBound
      let end = range.upperBound
      let d = FetchDescriptor<TransactionRecord>(
        predicate: #Predicate {
          $0.toAccountId == aid && $0.recurPeriod == nil && $0.date >= start && $0.date <= end
        },
        sortBy: sortDescriptors
      )
      return d

    case (.toAccount, .some(_), .some(let range), nil) where isScheduled:
      let aid = accountId!
      let start = range.lowerBound
      let end = range.upperBound
      let d = FetchDescriptor<TransactionRecord>(
        predicate: #Predicate {
          $0.toAccountId == aid && $0.recurPeriod != nil && $0.date >= start && $0.date <= end
        },
        sortBy: sortDescriptors
      )
      return d

    // --- Fallback: no profileId filter, apply everything else in memory ---
    default:
      let d = FetchDescriptor<TransactionRecord>(
        sortBy: sortDescriptors
      )
      return d
    }
  }

  func create(_ transaction: Transaction) async throws -> Transaction {
    let signpostID = OSSignpostID(log: Signposts.repository)
    os_signpost(
      .begin, log: Signposts.repository, name: "TransactionRepo.create", signpostID: signpostID)
    defer {
      os_signpost(
        .end, log: Signposts.repository, name: "TransactionRepo.create", signpostID: signpostID)
    }
    if transaction.type == .transfer {
      guard transaction.toAccountId != nil else {
        throw BackendError.validationFailed("Transfer must have a destination account")
      }
      guard transaction.toAccountId != transaction.accountId else {
        throw BackendError.validationFailed("Cannot transfer to the same account")
      }
    }
    let record = TransactionRecord.from(transaction)
    try await MainActor.run {
      context.insert(record)

      // Update cached account balances for non-scheduled transactions
      if transaction.recurPeriod == nil {
        if let accountId = transaction.accountId {
          try updateAccountBalance(accountId: accountId, delta: transaction.amount.cents)
        }
        if let toAccountId = transaction.toAccountId {
          try updateAccountBalance(accountId: toAccountId, delta: -transaction.amount.cents)
        }
      }

      try context.save()
      onRecordChanged(transaction.id)
    }
    return transaction
  }

  func update(_ transaction: Transaction) async throws -> Transaction {
    let signpostID = OSSignpostID(log: Signposts.repository)
    os_signpost(
      .begin, log: Signposts.repository, name: "TransactionRepo.update", signpostID: signpostID)
    defer {
      os_signpost(
        .end, log: Signposts.repository, name: "TransactionRepo.update", signpostID: signpostID)
    }
    let txnId = transaction.id
    let descriptor = FetchDescriptor<TransactionRecord>(
      predicate: #Predicate { $0.id == txnId }
    )

    try await MainActor.run {
      guard let record = try context.fetch(descriptor).first else {
        throw BackendError.serverError(404)
      }

      // Reverse old balance effect before applying new values (non-scheduled only)
      let oldWasScheduled = record.recurPeriod != nil
      if !oldWasScheduled {
        if let oldAccountId = record.accountId {
          try updateAccountBalance(accountId: oldAccountId, delta: -record.amount)
        }
        if let oldToAccountId = record.toAccountId {
          try updateAccountBalance(accountId: oldToAccountId, delta: record.amount)
        }
      }

      record.type = transaction.type.rawValue
      record.date = transaction.date
      record.accountId = transaction.accountId
      record.toAccountId = transaction.toAccountId
      record.amount = transaction.amount.cents
      record.currencyCode = transaction.amount.currency.code
      record.payee = transaction.payee
      record.notes = transaction.notes
      record.categoryId = transaction.categoryId
      record.earmarkId = transaction.earmarkId
      record.recurPeriod = transaction.recurPeriod?.rawValue
      record.recurEvery = transaction.recurEvery

      // Apply new balance effect (non-scheduled only)
      if transaction.recurPeriod == nil {
        if let accountId = transaction.accountId {
          try updateAccountBalance(accountId: accountId, delta: transaction.amount.cents)
        }
        if let toAccountId = transaction.toAccountId {
          try updateAccountBalance(accountId: toAccountId, delta: -transaction.amount.cents)
        }
      }

      try context.save()
      onRecordChanged(transaction.id)
    }
    return transaction
  }

  func delete(id: UUID) async throws {
    let signpostID = OSSignpostID(log: Signposts.repository)
    os_signpost(
      .begin, log: Signposts.repository, name: "TransactionRepo.delete", signpostID: signpostID)
    defer {
      os_signpost(
        .end, log: Signposts.repository, name: "TransactionRepo.delete", signpostID: signpostID)
    }
    let descriptor = FetchDescriptor<TransactionRecord>(
      predicate: #Predicate { $0.id == id }
    )

    try await MainActor.run {
      guard let record = try context.fetch(descriptor).first else {
        throw BackendError.serverError(404)
      }

      // Reverse balance effect before deleting (non-scheduled only)
      if record.recurPeriod == nil {
        if let accountId = record.accountId {
          try updateAccountBalance(accountId: accountId, delta: -record.amount)
        }
        if let toAccountId = record.toAccountId {
          try updateAccountBalance(accountId: toAccountId, delta: record.amount)
        }
      }

      context.delete(record)
      try context.save()
      onRecordDeleted(id)
    }
  }

  // MARK: - Cached Balance Maintenance

  @MainActor
  private func updateAccountBalance(accountId: UUID, delta: Int) throws {
    let descriptor = FetchDescriptor<AccountRecord>(
      predicate: #Predicate { $0.id == accountId }
    )
    if let record = try context.fetch(descriptor).first {
      record.cachedBalance = (record.cachedBalance ?? 0) + delta
    }
  }

  func fetchPayeeSuggestions(prefix: String) async throws -> [String] {
    let signpostID = OSSignpostID(log: Signposts.repository)
    os_signpost(
      .begin, log: Signposts.repository, name: "TransactionRepo.fetchPayeeSuggestions",
      signpostID: signpostID)
    defer {
      os_signpost(
        .end, log: Signposts.repository, name: "TransactionRepo.fetchPayeeSuggestions",
        signpostID: signpostID)
    }
    guard !prefix.isEmpty else { return [] }
    let descriptor = FetchDescriptor<TransactionRecord>(
      predicate: #Predicate { $0.payee != nil }
    )

    return try await MainActor.run {
      let records = try context.fetch(descriptor)
      let lowered = prefix.lowercased()
      let matching = records.compactMap(\.payee)
        .filter { !$0.isEmpty && $0.lowercased().hasPrefix(lowered) }

      var counts: [String: Int] = [:]
      for payee in matching {
        counts[payee, default: 0] += 1
      }
      return counts.sorted { $0.value > $1.value }.map(\.key)
    }
  }
}
