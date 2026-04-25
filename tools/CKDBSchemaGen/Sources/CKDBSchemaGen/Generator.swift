import Foundation

/// Emits Swift source for the generated wire layer from a parsed `Schema`.
enum Generator {

  /// One generated Swift file: relative path under the output directory and
  /// its contents. The CLI is responsible for writing these to disk.
  struct File: Equatable {
    let path: String
    let contents: String
  }

  /// Produces one wire-struct file per non-system, non-deprecated record
  /// type. Deprecated *fields* on a non-deprecated record type are skipped
  /// entirely — their declarations remain in `.ckdb` for additive-only
  /// Production but the Swift wire layer pretends they do not exist.
  static func generate(_ schema: Schema) -> [File] {
    schema.recordTypes
      .filter { !SystemRecordType.names.contains($0.name) }
      .filter { !$0.isDeprecated }
      .map { type in
        File(
          path: "\(type.name)CloudKitFields.swift",
          contents: render(type)
        )
      }
  }

  // MARK: - Internals

  private static func render(_ type: RecordType) -> String {
    let liveFields = type.fields.filter { !$0.isDeprecated }
    let lines: [String] = [
      "// THIS FILE IS GENERATED. Do not edit by hand.",
      "// Source: CloudKit/schema.ckdb. Regenerate with: just generate.",
      "",
      "import CloudKit",
      "import Foundation",
      "",
      "struct \(type.name)CloudKitFields {",
      properties(of: liveFields),
      "",
      allFieldNamesDecl(liveFields),
      "",
      memberwiseInit(liveFields),
      "",
      ckRecordInit(liveFields),
      "",
      writeMethod(liveFields),
      "}",
      "",
    ]
    return lines.joined(separator: "\n")
  }

  private static func properties(of fields: [Field]) -> String {
    fields.map { "  var \($0.name): \(swiftType(of: $0.type))?" }.joined(separator: "\n")
  }

  private static func allFieldNamesDecl(_ fields: [Field]) -> String {
    let names = fields.map { "\"\($0.name)\"" }.joined(separator: ", ")
    return "  static let allFieldNames: [String] = [\(names)]"
  }

  private static func memberwiseInit(_ fields: [Field]) -> String {
    let params = fields.map { "    \($0.name): \(swiftType(of: $0.type))? = nil" }
      .joined(separator: ",\n")
    let assigns = fields.map { "    self.\($0.name) = \($0.name)" }.joined(separator: "\n")
    return """
        init(
      \(params)
        ) {
      \(assigns)
        }
      """
  }

  private static func ckRecordInit(_ fields: [Field]) -> String {
    let lines = fields.map {
      "    self.\($0.name) = record[\"\($0.name)\"] as? \(swiftType(of: $0.type))"
    }.joined(separator: "\n")
    return """
        init(from record: CKRecord) {
      \(lines)
        }
      """
  }

  private static func writeMethod(_ fields: [Field]) -> String {
    let lines = fields.map {
      "    if let \($0.name) { record[\"\($0.name)\"] = \($0.name) as CKRecordValue }"
    }.joined(separator: "\n")
    return """
        func write(to record: CKRecord) {
      \(lines)
        }
      """
  }

  private static func swiftType(of fieldType: FieldType) -> String {
    switch fieldType {
    case .string: return "String"
    case .int64: return "Int64"
    case .double: return "Double"
    case .timestamp: return "Date"
    case .bytes: return "Data"
    case .reference: return "CKRecord.Reference"  // not currently used by user fields
    case .listInt64: return "[Int64]"
    }
  }
}
