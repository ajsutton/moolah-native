import Testing

@testable import CKDBSchemaGen

@Suite("Additivity")
struct AdditivityTests {

  private let baseline = Schema(recordTypes: [
    RecordType(
      name: "AccountRecord",
      fields: [
        Field(
          name: "name", type: .string, indexes: [.queryable, .searchable, .sortable],
          isDeprecated: false),
        Field(
          name: "position", type: .int64, indexes: [.queryable, .sortable], isDeprecated: false),
      ],
      isDeprecated: false
    ),
    RecordType(
      name: "ProfileRecord",
      fields: [
        Field(
          name: "label", type: .string, indexes: [.queryable, .searchable, .sortable],
          isDeprecated: false)
      ],
      isDeprecated: false
    ),
  ])

  @Test("identical schemas are additive")
  func identicalIsAdditive() {
    let result = Additivity.check(proposed: baseline, baseline: baseline)
    #expect(result.violations.isEmpty)
  }

  @Test("adding a field is additive")
  func addingFieldIsAdditive() {
    var proposed = baseline
    proposed.recordTypes[0].fields.append(
      Field(name: "isHidden", type: .int64, indexes: [.queryable, .sortable], isDeprecated: false))
    let result = Additivity.check(proposed: proposed, baseline: baseline)
    #expect(result.violations.isEmpty)
  }

  @Test("adding a record type is additive")
  func addingRecordTypeIsAdditive() {
    var proposed = baseline
    proposed.recordTypes.append(
      RecordType(
        name: "NewRecord",
        fields: [Field(name: "x", type: .string, indexes: [.queryable], isDeprecated: false)],
        isDeprecated: false))
    let result = Additivity.check(proposed: proposed, baseline: baseline)
    #expect(result.violations.isEmpty)
  }

  @Test("removing a field is a violation")
  func removingFieldFails() {
    var proposed = baseline
    proposed.recordTypes[0].fields.removeLast()  // drop position
    let result = Additivity.check(proposed: proposed, baseline: baseline)
    #expect(result.violations.contains { $0.contains("position") && $0.contains("AccountRecord") })
  }

  @Test("marking a field deprecated is additive")
  func deprecatingFieldIsAdditive() {
    var proposed = baseline
    proposed.recordTypes[0].fields[1].isDeprecated = true
    let result = Additivity.check(proposed: proposed, baseline: baseline)
    #expect(result.violations.isEmpty)
  }

  @Test("removing a record type is a violation")
  func removingRecordTypeFails() {
    var proposed = baseline
    proposed.recordTypes.removeLast()  // drop ProfileRecord
    let result = Additivity.check(proposed: proposed, baseline: baseline)
    #expect(result.violations.contains { $0.contains("ProfileRecord") })
  }

  @Test("changing a field's type is a violation")
  func changingTypeFails() {
    var proposed = baseline
    proposed.recordTypes[0].fields[0].type = .int64
    let result = Additivity.check(proposed: proposed, baseline: baseline)
    #expect(
      result.violations.contains {
        $0.contains("name") && $0.contains("STRING") && $0.contains("INT64")
      })
  }

  @Test("removing an index from a field is a violation")
  func removingIndexFails() {
    var proposed = baseline
    proposed.recordTypes[0].fields[0].indexes.remove(.searchable)
    let result = Additivity.check(proposed: proposed, baseline: baseline)
    #expect(result.violations.contains { $0.contains("name") && $0.contains("SEARCHABLE") })
  }

  @Test("adding an index is additive")
  func addingIndexIsAdditive() {
    var proposed = baseline
    proposed.recordTypes[1].fields[0].indexes.insert(.sortable)
    let result = Additivity.check(proposed: proposed, baseline: baseline)
    #expect(result.violations.isEmpty)
  }
}
