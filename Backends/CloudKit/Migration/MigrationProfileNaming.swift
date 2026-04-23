import Foundation

/// Pure naming logic for migration: determines labels for source (Remote) and target (iCloud) profiles.
///
/// Extracted from `MigrationCoordinator.swift` so the coordinator stays under
/// SwiftLint's `file_length` threshold. This type has no dependencies on the
/// coordinator's state machine or CloudKit — it is a set of deterministic
/// string transforms exercised directly by unit tests.
enum MigrationProfileNaming {
  private static let remoteSuffix = " (Remote)"
  private static let iCloudSuffix = " (iCloud)"

  /// Label for the original remote profile: appends "(Remote)" unless it already has it
  /// (possibly with a dedup number like "(Remote) 2").
  static func sourceLabel(for label: String) -> String {
    if label.hasSuffix(remoteSuffix) {
      return label
    }
    // Check for deduplicated remote names like "Foo (Remote) 2"
    if let range = label.range(of: remoteSuffix, options: .backwards) {
      let remainder = label[range.upperBound...]
      if remainder.isEmpty || Int(remainder.trimmingCharacters(in: .whitespaces)) != nil {
        return label
      }
    }
    return label + remoteSuffix
  }

  /// Label for the new iCloud profile: replaces trailing "(Remote)" with "(iCloud)", or appends "(iCloud)".
  static func targetLabel(for label: String) -> String {
    if label.hasSuffix(remoteSuffix) {
      return String(label.dropLast(remoteSuffix.count)) + iCloudSuffix
    }
    if label.hasSuffix(iCloudSuffix) {
      return label
    }
    return label + iCloudSuffix
  }

  /// Returns `name` if it is not in `existingLabels`, otherwise appends " 2", " 3", etc.
  static func uniqueName(_ name: String, among existingLabels: [String]) -> String {
    let existing = Set(existingLabels)
    if !existing.contains(name) { return name }
    var counter = 2
    while existing.contains("\(name) \(counter)") {
      counter += 1
    }
    return "\(name) \(counter)"
  }

  /// Returns `(sourceLabel, targetLabel)` with deduplication against existing profile labels.
  static func migratedLabels(
    sourceLabel: String,
    existingLabels: [String]
  ) -> (source: String, target: String) {
    let rawSource = self.sourceLabel(for: sourceLabel)
    let rawTarget = self.targetLabel(for: sourceLabel)

    let dedupedTarget = uniqueName(rawTarget, among: existingLabels)
    // For source dedup, also exclude the original sourceLabel since it will be renamed
    let dedupedSource = uniqueName(rawSource, among: existingLabels)

    return (dedupedSource, dedupedTarget)
  }
}
