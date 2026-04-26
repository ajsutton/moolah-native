import Testing

@testable import CKDBSchemaGen

@Suite("Equality")
struct EqualityTests {

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

  @Test("identical schemas are equal")
  func identicalIsEqual() {
    let result = Equality.check(baseline, baseline)
    #expect(result.isEqual)
    #expect(result.differences.isEmpty)
  }

  @Test("record-type order does not matter")
  func recordTypeOrderIndependent() {
    let reordered = Schema(recordTypes: baseline.recordTypes.reversed())
    let result = Equality.check(baseline, reordered)
    #expect(result.isEqual)
  }

  @Test("field order does not matter")
  func fieldOrderIndependent() {
    var swapped = baseline
    swapped.recordTypes[0].fields.reverse()
    let result = Equality.check(baseline, swapped)
    #expect(result.isEqual)
  }

  @Test("missing record type is reported on the right side")
  func missingRecordTypeReported() {
    var trimmed = baseline
    trimmed.recordTypes.removeLast()  // drop ProfileRecord
    let result = Equality.check(baseline, trimmed, aLabel: "left", bLabel: "right")
    #expect(!result.isEqual)
    #expect(
      result.differences.contains {
        $0.contains("ProfileRecord") && $0.contains("left") && $0.contains("right")
      })
  }

  @Test("missing field is reported on the right side")
  func missingFieldReported() {
    var trimmed = baseline
    trimmed.recordTypes[0].fields.removeLast()  // drop position from AccountRecord
    let result = Equality.check(baseline, trimmed, aLabel: "left", bLabel: "right")
    #expect(!result.isEqual)
    #expect(
      result.differences.contains {
        $0.contains("AccountRecord.position") && $0.contains("left") && $0.contains("right")
      })
  }

  @Test("type difference is reported")
  func typeDifferenceReported() {
    var changed = baseline
    changed.recordTypes[0].fields[0].type = .int64  // change AccountRecord.name to INT64
    let result = Equality.check(baseline, changed)
    #expect(!result.isEqual)
    #expect(
      result.differences.contains {
        $0.contains("AccountRecord.name") && $0.contains("STRING") && $0.contains("INT64")
      })
  }

  @Test("index difference is reported with side-specific detail")
  func indexDifferenceReported() {
    var changed = baseline
    changed.recordTypes[0].fields[0].indexes.remove(.searchable)
    let result = Equality.check(baseline, changed, aLabel: "left", bLabel: "right")
    #expect(!result.isEqual)
    #expect(
      result.differences.contains {
        $0.contains("AccountRecord.name") && $0.contains("SEARCHABLE") && $0.contains("left-only")
      })
  }

  @Test("deprecation difference on a field is reported")
  func fieldDeprecationDifferenceReported() {
    var changed = baseline
    changed.recordTypes[0].fields[1].isDeprecated = true
    let result = Equality.check(baseline, changed)
    #expect(!result.isEqual)
    #expect(
      result.differences.contains {
        $0.contains("AccountRecord.position") && $0.contains("deprecation")
      })
  }

  @Test("equality is symmetric")
  func symmetric() {
    var changed = baseline
    changed.recordTypes[0].fields[0].type = .int64
    let forward = Equality.check(baseline, changed)
    let reverse = Equality.check(changed, baseline)
    #expect(!forward.isEqual)
    #expect(!reverse.isEqual)
    #expect(forward.differences.count == reverse.differences.count)
  }
}
