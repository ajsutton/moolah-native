import Foundation

/// Checks whether a proposed `Schema` is additive over a baseline `Schema`.
/// Additive means: no record types removed, no fields removed, no field type
/// changes, no indexes removed. Adding types, fields, indexes, or marking
/// existing fields `// DEPRECATED` (which is not removal — the field stays in
/// the manifest) are all permitted.
enum Additivity {

  struct Result: Equatable {
    var violations: [String]
  }

  static func check(proposed: Schema, baseline: Schema) -> Result {
    var violations: [String] = []
    for baselineType in baseline.recordTypes {
      guard let proposedType = proposed.recordType(named: baselineType.name) else {
        violations.append(
          "record type '\(baselineType.name)' is in baseline but missing from proposed")
        continue
      }
      for baselineField in baselineType.fields {
        guard let proposedField = proposedType.field(named: baselineField.name) else {
          violations.append(
            "field '\(baselineField.name)' on '\(baselineType.name)' is in baseline but missing from proposed"
          )
          continue
        }
        if proposedField.type != baselineField.type {
          violations.append(
            "field '\(baselineField.name)' on '\(baselineType.name)' changed type "
              + "(\(baselineField.type.rawValue) -> \(proposedField.type.rawValue))")
        }
        for index in baselineField.indexes where !proposedField.indexes.contains(index) {
          violations.append(
            "field '\(baselineField.name)' on '\(baselineType.name)' lost index "
              + "\(index.rawValue) (was \(baselineField.indexes.map(\.rawValue).sorted().joined(separator: ", ")))"
          )
        }
      }
    }
    return Result(violations: violations)
  }
}
