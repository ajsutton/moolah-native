import Foundation
import GRDB

@testable import Moolah

/// Shared helpers for the `EXPLAIN QUERY PLAN`-pinning suites that
/// validate index usage on the GRDB hot paths. Hoisted from the three
/// per-suite copies (`AnalysisPlanPinningTests`,
/// `AnalysisAggregationPlanPinningTests`, `CSVImportPlanPinningTests`)
/// so the suites stay self-contained without duplicating the `EXPLAIN
/// QUERY PLAN` fetch/format glue.
///
/// Case-less enum used as a namespace per `guides/CODE_GUIDE.md` §5.
enum PlanPinningTestHelpers {
  /// Open a fresh in-memory `ProfileDatabase` (runs the migrator and
  /// creates every v3 table and index). Each call returns an
  /// independent queue so plan-pinning tests don't share state.
  static func makeDatabase() throws -> DatabaseQueue {
    try ProfileDatabase.openInMemory()
  }

  /// Returns the joined `detail` column from the EXPLAIN QUERY PLAN
  /// rows for the given query. Callers pass the bare query SQL (without
  /// the `EXPLAIN QUERY PLAN` prefix) — the helper builds an `SQL`
  /// literal that splices the caller's query in via GRDB's `\(sql:)`
  /// raw-fragment interpolation. The `EXPLAIN QUERY PLAN ` prefix is a
  /// compile-time string literal and the caller's `query` is also a
  /// string literal at every call site (the pinning suites build SQL
  /// against fixed SELECT statements, no end-user input flows through
  /// here), so the composition stays safe per
  /// `guides/DATABASE_CODE_GUIDE.md` §4 — and the helper passes a
  /// `literal:` argument to GRDB rather than a freeform `sql:` string,
  /// matching the pattern used by the production aggregation queries.
  /// Joining the `detail` column keeps `contains` checks readable and
  /// matches the format the SQLite docs use to describe plans.
  static func planDetail(
    _ database: DatabaseQueue, query: String, arguments: StatementArguments = []
  ) throws -> String {
    try database.read { database in
      let planSQL: SQL = "EXPLAIN QUERY PLAN \(sql: query, arguments: arguments)"
      let rows = try SQLRequest<Row>(literal: planSQL).fetchAll(database)
      return rows.compactMap { $0["detail"] as String? }.joined(separator: "; ")
    }
  }

  /// Returns `true` when SQLite's plan reports a *full table scan* of
  /// the given alias — i.e. `SCAN <alias>` not followed by an index
  /// clause. SQLite emits `SCAN leg USING INDEX X` (or
  /// `USING COVERING INDEX X`) for index-driven reads — those should
  /// not trip the assertion. A bare `SCAN leg` (followed by `;`,
  /// end-of-string, or anything other than ` USING`) is the
  /// no-index case the negative assertion exists to catch.
  ///
  /// Hoisted into a helper because the previous string-contains shape
  /// (`detail.contains("SCAN transaction_leg")`) was a false negative
  /// for aliased queries — SQLite's plan output uses the alias, never
  /// the base table name, so the bare-name check would silently pass
  /// even on a real full scan.
  static func planHasFullTableScanOf(_ detail: String, alias: String) -> Bool {
    let scan = "SCAN \(alias)"
    var searchRange = detail.startIndex..<detail.endIndex
    while let match = detail.range(of: scan, range: searchRange) {
      let afterMatch = match.upperBound
      if afterMatch == detail.endIndex {
        return true
      }
      // Index-driven scans always have ` USING ` immediately after the
      // alias. Anything else (`;`, `,`, end-of-string) is a bare scan.
      let suffix = detail[afterMatch...]
      if !suffix.hasPrefix(" USING ") {
        return true
      }
      searchRange = afterMatch..<detail.endIndex
    }
    return false
  }
}
