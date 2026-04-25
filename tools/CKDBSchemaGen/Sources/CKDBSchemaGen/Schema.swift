import Foundation

/// In-memory representation of a parsed `.ckdb` schema. Used as the
/// intermediate form between the parser, the code generator, and the
/// additivity checker.
struct Schema: Equatable {
  var recordTypes: [RecordType]

  /// Returns the record type with the given name, or nil if absent.
  func recordType(named name: String) -> RecordType? {
    recordTypes.first { $0.name == name }
  }
}

/// A single `RECORD TYPE` block.
struct RecordType: Equatable {
  var name: String
  var fields: [Field]
  var isDeprecated: Bool

  /// Returns the field with the given name, or nil if absent.
  func field(named name: String) -> Field? {
    fields.first { $0.name == name }
  }
}

/// A single field declaration inside a `RECORD TYPE` block. Excludes
/// system fields (those whose names begin with `___`) and `GRANT` lines —
/// the parser filters those out.
struct Field: Equatable {
  var name: String
  var type: FieldType
  var indexes: Set<FieldIndex>
  var isDeprecated: Bool
}

/// CloudKit field types we currently use.
enum FieldType: String, Equatable {
  case string = "STRING"
  case int64 = "INT64"
  case double = "DOUBLE"
  case timestamp = "TIMESTAMP"
  case bytes = "BYTES"
  case reference = "REFERENCE"
  case listInt64 = "LIST<INT64>"
}

/// Index attributes that may appear after a field's type.
enum FieldIndex: String, Equatable, Hashable, CaseIterable {
  case queryable = "QUERYABLE"
  case searchable = "SEARCHABLE"
  case sortable = "SORTABLE"
}

/// Names of system types that are auto-created by CloudKit. The generator
/// skips these because there is no Swift adapter to refactor.
enum SystemRecordType {
  static let names: Set<String> = ["Users"]
}
