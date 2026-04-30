import CloudKit
import Foundation

/// Protocol for bidirectional conversion between record types and CKRecords.
protocol CloudKitRecordConvertible {
  static var recordType: String { get }

  /// Converts this record to a CKRecord in the given zone.
  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord

  /// Extracts field values from a CKRecord. Returns a new instance with the extracted values,
  /// or `nil` if the `CKRecord` does not carry a valid identifier for this record type.
  /// For UUID-keyed conformers (everything except `InstrumentRow`) this means
  /// `recordID.uuid == nil`. `InstrumentRow` is keyed by `recordID.recordName`, which
  /// is always present on a valid `CKRecord.ID`, so it never returns `nil`.
  ///
  /// Callers are expected to log and skip when this returns `nil` so a malformed incoming
  /// record surfaces as an error rather than a phantom row with a fresh random id.
  static func fieldValues(from ckRecord: CKRecord) -> Self?
}

/// Protocol for records that have a UUID `id` property.
/// Used by `buildCKRecord` to look up cached system fields by record name.
protocol IdentifiableRecord {
  var id: UUID { get }
}

extension ProfileRecord: IdentifiableRecord {}
// `InstrumentRow` is string-keyed; no `IdentifiableRecord` conformance.
extension AccountRow: IdentifiableRecord {}
extension TransactionRow: IdentifiableRecord {}
extension TransactionLegRow: IdentifiableRecord {}
extension CategoryRow: IdentifiableRecord {}
extension EarmarkRow: IdentifiableRecord {}
extension EarmarkBudgetItemRow: IdentifiableRecord {}
extension InvestmentValueRow: IdentifiableRecord {}
extension CSVImportProfileRow: IdentifiableRecord {}
extension ImportRuleRow: IdentifiableRecord {}

/// Protocol for records that can store CKRecord system fields.
///
/// Constrained to `AnyObject` because the `ProfileRecord` write path
/// mutates a fetched `@Model` row in place via
/// `record.encodedSystemFields = data`. GRDB row structs deliberately
/// do not conform — system-fields writes for those record types route
/// through the repository's `setEncodedSystemFieldsSync(id:data:)` SQL
/// UPDATE instead.
protocol SystemFieldsCacheable: AnyObject {
  var encodedSystemFields: Data? { get set }
}

extension ProfileRecord: SystemFieldsCacheable {}

/// Value-type sibling of `SystemFieldsCacheable` for GRDB row structs.
///
/// `SystemFieldsCacheable` is `AnyObject`-constrained because the
/// SwiftData write path mutates a fetched `@Model` in place. GRDB row
/// structs cannot conform to it, but they still expose the cached
/// CKRecord change-tag blob through `var encodedSystemFields: Data?`.
/// `ValueTypeSystemFieldsReadable` lets the upload-side
/// `mapBuiltRows(_:)` path read that blob through a single typed
/// constraint instead of a dynamic-type cast chain.
///
/// This protocol is read-only because the GRDB write path uses
/// `setEncodedSystemFieldsSync(id:data:)` SQL UPDATEs rather than
/// mutating the in-memory row.
protocol ValueTypeSystemFieldsReadable {
  var encodedSystemFields: Data? { get }
}

extension CSVImportProfileRow: ValueTypeSystemFieldsReadable {}
extension ImportRuleRow: ValueTypeSystemFieldsReadable {}
extension InstrumentRow: ValueTypeSystemFieldsReadable {}
extension AccountRow: ValueTypeSystemFieldsReadable {}
extension CategoryRow: ValueTypeSystemFieldsReadable {}
extension EarmarkRow: ValueTypeSystemFieldsReadable {}
extension EarmarkBudgetItemRow: ValueTypeSystemFieldsReadable {}
extension TransactionRow: ValueTypeSystemFieldsReadable {}
extension TransactionLegRow: ValueTypeSystemFieldsReadable {}
extension InvestmentValueRow: ValueTypeSystemFieldsReadable {}

// MARK: - CKRecord System Fields

extension CKRecord {
  /// Encodes the record's system fields (including the change tag) for caching.
  /// Used to preserve change tags across uploads and avoid `.serverRecordChanged` conflicts.
  var encodedSystemFields: Data {
    let coder = NSKeyedArchiver(requiringSecureCoding: true)
    encodeSystemFields(with: coder)
    coder.finishEncoding()
    return coder.encodedData
  }

  /// Creates a CKRecord from previously cached system fields.
  /// Returns nil if the data is invalid.
  static func fromEncodedSystemFields(_ data: Data) -> CKRecord? {
    guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
    coder.requiresSecureCoding = true
    return CKRecord(coder: coder)
  }
}

// MARK: - Lookup Helper

/// Maps CKRecord.recordType strings to the corresponding record types for dispatching.
enum RecordTypeRegistry: Sendable {
  nonisolated(unsafe) static let allTypes: [String: any CloudKitRecordConvertible.Type] = [
    // Every record type now dispatches to its GRDB row type. The
    // CloudKit wire `recordType` strings are frozen contracts and
    // remain byte-identical to the original SwiftData @Model class
    // names; only the local Swift type bound to each key changes.
    // The legacy `ProfileRecord` SwiftData class remains in the build
    // for the one-shot Phase A migrator to read from; once Phase B
    // runs (a release after this one) the class is deleted entirely.
    ProfileRow.recordType: ProfileRow.self,
    InstrumentRow.recordType: InstrumentRow.self,
    AccountRow.recordType: AccountRow.self,
    TransactionRow.recordType: TransactionRow.self,
    TransactionLegRow.recordType: TransactionLegRow.self,
    CategoryRow.recordType: CategoryRow.self,
    EarmarkRow.recordType: EarmarkRow.self,
    EarmarkBudgetItemRow.recordType: EarmarkBudgetItemRow.self,
    InvestmentValueRow.recordType: InvestmentValueRow.self,
    CSVImportProfileRow.recordType: CSVImportProfileRow.self,
    ImportRuleRow.recordType: ImportRuleRow.self,
  ]
}
