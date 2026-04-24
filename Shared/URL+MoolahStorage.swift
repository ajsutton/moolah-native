import Foundation

extension URL {
  /// Test-only override for the Application Support root. Production code
  /// should leave this `nil`; tests set it to a temporary directory and reset
  /// it in a defer block.
  nonisolated(unsafe) static var moolahApplicationSupportOverride: URL?

  /// Application Support, scoped to the current CloudKit environment.
  ///
  /// Use this for any on-disk state tied to a CloudKit container: SwiftData
  /// stores, sync-state files, `CKSyncEngine` serialisations, nightly
  /// backups. The subdirectory is created on demand so callers never need to
  /// guard on its existence.
  static var moolahScopedApplicationSupport: URL {
    let root = moolahApplicationSupportOverride ?? URL.applicationSupportDirectory
    let scoped = root.appending(path: CloudKitEnvironment.resolved().storageSubdirectory)
    try? FileManager.default.createDirectory(at: scoped, withIntermediateDirectories: true)
    return scoped
  }
}
