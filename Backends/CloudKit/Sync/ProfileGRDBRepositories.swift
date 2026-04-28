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
/// **Sendable.** `@unchecked Sendable` because the bundle is captured by
/// reference into `ProfileDataSyncHandler.grdbRepositories` (a
/// `nonisolated let`) and read from CKSyncEngine's delegate executor.
/// The two members are themselves classes annotated `@unchecked
/// Sendable`, the bundle's stored properties are `let`, and nothing
/// mutates the struct after init — the `@unchecked` waiver is the
/// pragmatic shape that mirrors the existing CloudKit repository
/// classes.
struct ProfileGRDBRepositories: @unchecked Sendable {
  let csvImportProfiles: GRDBCSVImportProfileRepository
  let importRules: GRDBImportRuleRepository
}
