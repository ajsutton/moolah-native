import Testing

@testable import CKDBSchemaGen

@Suite("Parser")
struct ParserTests {

  @Test("parses a single record type with one field")
  func singleRecordOneField() throws {
    let source = """
      DEFINE SCHEMA

          RECORD TYPE AccountRecord (
              "___createTime" TIMESTAMP,
              "___recordID"   REFERENCE QUERYABLE,
              name            STRING QUERYABLE SEARCHABLE SORTABLE,
              GRANT WRITE TO "_creator"
          );
      """
    let schema = try Parser.parse(source)
    #expect(schema.recordTypes.count == 1)
    let account = try #require(schema.recordType(named: "AccountRecord"))
    #expect(account.fields.count == 1)
    let name = try #require(account.field(named: "name"))
    #expect(name.type == .string)
    #expect(name.indexes == [.queryable, .searchable, .sortable])
    #expect(name.isDeprecated == false)
  }

  @Test("parses every supported field type")
  func allFieldTypes() throws {
    let source = """
      DEFINE SCHEMA
          RECORD TYPE T (
              "___recordID" REFERENCE QUERYABLE,
              s             STRING QUERYABLE SEARCHABLE SORTABLE,
              i             INT64 QUERYABLE SORTABLE,
              d             DOUBLE QUERYABLE SORTABLE,
              t             TIMESTAMP QUERYABLE SORTABLE,
              b             BYTES,
              roles         LIST<INT64>
          );
      """
    let schema = try Parser.parse(source)
    let t = try #require(schema.recordType(named: "T"))
    #expect(t.field(named: "s")?.type == .string)
    #expect(t.field(named: "i")?.type == .int64)
    #expect(t.field(named: "d")?.type == .double)
    #expect(t.field(named: "t")?.type == .timestamp)
    #expect(t.field(named: "b")?.type == .bytes)
    #expect(t.field(named: "roles")?.type == .listInt64)
    #expect(t.field(named: "b")?.indexes.isEmpty == true)
  }

  @Test("filters system fields and GRANT lines")
  func filtersSystemAndGrants() throws {
    let source = """
      DEFINE SCHEMA
          RECORD TYPE T (
              "___createTime" TIMESTAMP,
              "___createdBy"  REFERENCE,
              "___etag"       STRING,
              "___modTime"    TIMESTAMP,
              "___modifiedBy" REFERENCE,
              "___recordID"   REFERENCE QUERYABLE,
              foo             STRING QUERYABLE SEARCHABLE SORTABLE,
              GRANT WRITE TO "_creator",
              GRANT CREATE TO "_icloud",
              GRANT READ TO "_world"
          );
      """
    let schema = try Parser.parse(source)
    let t = try #require(schema.recordType(named: "T"))
    #expect(t.fields.map(\.name) == ["foo"])
  }

  @Test("flags fields preceded by // DEPRECATED")
  func deprecatedField() throws {
    let source = """
      DEFINE SCHEMA
          RECORD TYPE T (
              "___recordID" REFERENCE QUERYABLE,
              foo           STRING QUERYABLE SEARCHABLE SORTABLE,
              // DEPRECATED: replaced by foo
              bar           STRING QUERYABLE SEARCHABLE SORTABLE
          );
      """
    let schema = try Parser.parse(source)
    let t = try #require(schema.recordType(named: "T"))
    #expect(t.field(named: "foo")?.isDeprecated == false)
    #expect(t.field(named: "bar")?.isDeprecated == true)
  }

  @Test("flags record types preceded by // DEPRECATED")
  func deprecatedRecordType() throws {
    let source = """
      DEFINE SCHEMA
          // DEPRECATED: replaced by NewRecord
          RECORD TYPE Old (
              "___recordID" REFERENCE QUERYABLE,
              foo           STRING QUERYABLE SEARCHABLE SORTABLE
          );
          RECORD TYPE NewRecord (
              "___recordID" REFERENCE QUERYABLE,
              foo           STRING QUERYABLE SEARCHABLE SORTABLE
          );
      """
    let schema = try Parser.parse(source)
    #expect(schema.recordType(named: "Old")?.isDeprecated == true)
    #expect(schema.recordType(named: "NewRecord")?.isDeprecated == false)
  }

  @Test("ignores ordinary // comments that are not DEPRECATED")
  func ignoresPlainComments() throws {
    let source = """
      DEFINE SCHEMA
          // a normal comment
          RECORD TYPE T (
              "___recordID" REFERENCE QUERYABLE,
              // a field comment
              foo           STRING QUERYABLE SEARCHABLE SORTABLE
          );
      """
    let schema = try Parser.parse(source)
    let t = try #require(schema.recordType(named: "T"))
    #expect(t.isDeprecated == false)
    #expect(t.field(named: "foo")?.isDeprecated == false)
  }

  @Test("rejects unknown field types")
  func rejectsUnknownType() {
    let source = """
      DEFINE SCHEMA
          RECORD TYPE T (
              "___recordID" REFERENCE QUERYABLE,
              foo           UNICORN QUERYABLE
          );
      """
    #expect(throws: Parser.Error.self) {
      try Parser.parse(source)
    }
  }

  @Test("rejects malformed input")
  func rejectsMalformed() {
    #expect(throws: Parser.Error.self) {
      try Parser.parse("garbage")
    }
  }
}
