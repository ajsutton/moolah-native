// Backends/CloudKit/Repositories/CategoryBalancesQuery.swift

import Foundation

/// Parameter bundle and per-leg accumulator for `fetchCategoryBalances`,
/// shared between every `AnalysisRepository` implementation. Keeping the
/// type in one place stops the GRDB and CloudKit copies from drifting
/// — the conversion-date rule (Rule 5 of
/// `guides/INSTRUMENT_CONVERSION_GUIDE.md`) and the per-instrument
/// arithmetic safety (Rule 1) live here, and any change has to land
/// once for both backends.
///
/// Conversion is delegated to `CloudKitAnalysisRepository.convertedAmount`,
/// which preserves the historic-snapshot date and applies the
/// single-instrument fast path.
struct CategoryBalancesQuery: Sendable {
  let dateRange: ClosedRange<Date>
  let transactionType: TransactionType
  let filters: TransactionFilter?
  let targetInstrument: Instrument
  let conversionService: any InstrumentConversionService

  func shouldInclude(_ transaction: Transaction) -> Bool {
    guard dateRange.contains(transaction.date) else { return false }
    guard transaction.recurPeriod == nil else { return false }
    if let accountId = filters?.accountId,
      !transaction.accountIds.contains(accountId)
    {
      return false
    }
    if let payee = filters?.payee, transaction.payee != payee {
      return false
    }
    return true
  }

  func accumulate(
    transaction: Transaction,
    into balances: inout [UUID: InstrumentAmount]
  ) async throws {
    for leg in transaction.legs {
      guard leg.type == transactionType else { continue }
      guard let categoryId = leg.categoryId else { continue }

      if let earmarkId = filters?.earmarkId, leg.earmarkId != earmarkId {
        continue
      }
      if let categoryIds = filters?.categoryIds, !categoryIds.isEmpty,
        !categoryIds.contains(categoryId)
      {
        continue
      }

      let amount = try await CloudKitAnalysisRepository.convertedAmount(
        leg,
        to: targetInstrument,
        on: transaction.date,
        conversionService: conversionService
      )
      balances[categoryId, default: .zero(instrument: targetInstrument)] += amount
    }
  }
}
