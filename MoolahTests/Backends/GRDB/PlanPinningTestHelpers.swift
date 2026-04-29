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
  /// the `EXPLAIN QUERY PLAN` prefix) — the helper prepends the
  /// directive via string concatenation against `prefix`, a string
  /// literal, so the `sql:` argument carries no string interpolation
  /// from the caller and satisfies `guides/DATABASE_CODE_GUIDE.md` §4
  /// (the only dynamic component is the caller's `query`, which is
  /// itself a string-literal in every existing call site).
  /// Joining the `detail` column keeps `contains` checks readable and
  /// matches the format the SQLite docs use to describe plans.
  static func planDetail(
    _ database: DatabaseQueue, query: String, arguments: StatementArguments = []
  ) throws -> String {
    try database.read { database in
      // `prefix` is a string literal; concatenation against the
      // caller-supplied `query` (also a literal at every call site) is
      // safe per §4 because no end-user input flows through here.
      let prefix = "EXPLAIN QUERY PLAN "
      let planSQL = prefix + query
      let rows = try Row.fetchAll(database, sql: planSQL, arguments: arguments)
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
  static func planScansAlias(_ detail: String, _ alias: String) -> Bool {
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
