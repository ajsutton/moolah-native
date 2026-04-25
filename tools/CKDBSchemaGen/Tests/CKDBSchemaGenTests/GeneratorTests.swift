import Testing

@testable import CKDBSchemaGen

@Suite("Generator")
struct GeneratorTests {

  private func makeSchema() -> Schema {
    Schema(recordTypes: [
      RecordType(
        name: "AccountRecord",
        fields: [
          Field(
            name: "name", type: .string, indexes: [.queryable, .searchable, .sortable],
            isDeprecated: false),
          Field(
            name: "position", type: .int64, indexes: [.queryable, .sortable], isDeprecated: false),
          Field(
            name: "isHidden", type: .int64, indexes: [.queryable, .sortable], isDeprecated: false),
          Field(
            name: "ratio", type: .double, indexes: [.queryable, .sortable], isDeprecated: false),
          Field(
            name: "lastUsedAt", type: .timestamp, indexes: [.queryable, .sortable],
            isDeprecated: false),
          Field(name: "blob", type: .bytes, indexes: [], isDeprecated: false),
        ],
        isDeprecated: false
      ),
      RecordType(
        name: "Users",
        fields: [
          Field(name: "roles", type: .listInt64, indexes: [], isDeprecated: false)
        ],
        isDeprecated: false
      ),
      RecordType(
        name: "OldRecord",
        fields: [
          Field(name: "x", type: .string, indexes: [.queryable], isDeprecated: false)
        ],
        isDeprecated: true
      ),
    ])
  }

  @Test("emits one file per non-system, non-deprecated record type")
  func emitsOneFilePerType() {
    let files = Generator.generate(makeSchema())
    let fileNames = files.map(\.path).sorted()
    #expect(fileNames == ["AccountRecordCloudKitFields.swift"])
  }

  @Test("file header marks the file as auto-generated")
  func fileHeader() {
    let file = Generator.generate(makeSchema()).first {
      $0.path == "AccountRecordCloudKitFields.swift"
    }!
    #expect(file.contents.contains("// THIS FILE IS GENERATED. Do not edit by hand."))
    #expect(
      file.contents.contains("// Source: CloudKit/schema.ckdb. Regenerate with: just generate."))
    #expect(file.contents.contains("import CloudKit"))
    #expect(file.contents.contains("import Foundation"))
  }

  @Test("declares one optional property per non-deprecated field, with the right type")
  func properties() {
    let contents = Generator.generate(makeSchema()).first {
      $0.path == "AccountRecordCloudKitFields.swift"
    }!.contents
    #expect(contents.contains("var name: String?"))
    #expect(contents.contains("var position: Int64?"))
    #expect(contents.contains("var isHidden: Int64?"))
    #expect(contents.contains("var ratio: Double?"))
    #expect(contents.contains("var lastUsedAt: Date?"))
    #expect(contents.contains("var blob: Data?"))
  }

  @Test("emits allFieldNames in declaration order")
  func allFieldNames() {
    let contents = Generator.generate(makeSchema()).first {
      $0.path == "AccountRecordCloudKitFields.swift"
    }!.contents
    #expect(
      contents.contains(
        #"static let allFieldNames: [String] = ["name", "position", "isHidden", "ratio", "lastUsedAt", "blob"]"#
      ))
  }

  @Test("init(from: CKRecord) reads each field by name")
  func initFromRecord() {
    let contents = Generator.generate(makeSchema()).first {
      $0.path == "AccountRecordCloudKitFields.swift"
    }!.contents
    #expect(contents.contains(#"self.name = record["name"] as? String"#))
    #expect(contents.contains(#"self.position = record["position"] as? Int64"#))
    #expect(contents.contains(#"self.lastUsedAt = record["lastUsedAt"] as? Date"#))
    #expect(contents.contains(#"self.blob = record["blob"] as? Data"#))
  }

  @Test("write(to:) writes only non-nil fields as CKRecordValue")
  func writeToRecord() {
    let contents = Generator.generate(makeSchema()).first {
      $0.path == "AccountRecordCloudKitFields.swift"
    }!.contents
    #expect(contents.contains(#"if let name { record["name"] = name as CKRecordValue }"#))
    #expect(contents.contains(#"if let blob { record["blob"] = blob as CKRecordValue }"#))
  }

  @Test("skips deprecated fields entirely")
  func skipsDeprecatedFields() {
    let schema = Schema(recordTypes: [
      RecordType(
        name: "T",
        fields: [
          Field(name: "live", type: .string, indexes: [.queryable], isDeprecated: false),
          Field(name: "old", type: .string, indexes: [.queryable], isDeprecated: true),
        ],
        isDeprecated: false
      )
    ])
    let contents = Generator.generate(schema).first { $0.path == "TCloudKitFields.swift" }!.contents
    #expect(contents.contains("var live: String?"))
    #expect(contents.contains("var old: String?") == false)
    #expect(contents.contains(#""old""#) == false)
  }
}
