// Backends/CloudKit/Sync/ProfileGRDBRepositories.swift

import Foundation

/// Bundle of the GRDB-backed repositories for the per-profile data
/// handler. Slice 0 of `plans/grdb-migration.md` migrates two record
/// types (`CSVImportProfile`, `ImportRule`) to GRDB; subsequent slices
/// extend this bundle and shrink the SwiftData footprint accordingly.
///
/// The dispatch tables in `ProfileDataSyncHandler+ApplyRemoteChanges` /
/// `+SystemFields` consult this bundle for record types that have moved
/// to GRDB and fall through to the SwiftData paths for everything else.
/// Both fields are non-optional because in-memory tests, previews, and
/// production all build the GRDB repos eagerly during backend
/// construction.
///
/// **Sendable.** Plain `Sendable` synthesis. Every stored property is
/// `let` and itself `Sendable` — the GRDB repositories are
/// `final class … : @unchecked Sendable`, which satisfies the
/// `Sendable` protocol requirement. The struct has no escape hatches,
/// so the compiler derives `Sendable` automatically and no
/// `@unchecked` waiver is needed.
struct ProfileGRDBRepositories: Sendable {
  let csvImportProfiles: GRDBCSVImportProfileRepository
  let importRules: GRDBImportRuleRepository
}
