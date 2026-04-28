import CloudKit
import Foundation

/// Protocol for bidirectional conversion between SwiftData records and CKRecords.
protocol CloudKitRecordConvertible {
  static var recordType: String { get }

  /// Converts this record to a CKRecord in the given zone.
  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord

  /// Extracts field values from a CKRecord. Returns a new instance with the extracted values,
  /// or `nil` if the `CKRecord` does not carry a valid identifier for this record type.
  /// For UUID-keyed conformers (everything except `InstrumentRecord`) this means
  /// `recordID.uuid == nil`. `InstrumentRecord` is keyed by `recordID.recordName`, which
  /// is always present on a valid `CKRecord.ID`, so it never returns `nil`.
  ///
  /// Callers are expected to log and skip when this returns `nil` so a malformed incoming
  /// record surfaces as an error rather than a phantom row with a fresh random id.
  ///
  /// Note: This does not create a managed @Model instance — it returns field values only.
  static func fieldValues(from ckRecord: CKRecord) -> Self?
}

/// Protocol for records that have a UUID `id` property.
/// Used by `buildCKRecord` to look up cached system fields by record name.
protocol IdentifiableRecord {
  var id: UUID { get }
}

extension AccountRecord: IdentifiableRecord {}
extension TransactionRecord: IdentifiableRecord {}
extension TransactionLegRecord: IdentifiableRecord {}
extension CategoryRecord: IdentifiableRecord {}
extension EarmarkRecord: IdentifiableRecord {}
extension EarmarkBudgetItemRecord: IdentifiableRecord {}
extension InvestmentValueRecord: IdentifiableRecord {}
extension ProfileRecord: IdentifiableRecord {}
extension CSVImportProfileRow: IdentifiableRecord {}
extension ImportRuleRow: IdentifiableRecord {}

/// Protocol for records that can store CKRecord system fields.
///
/// Constrained to `AnyObject` because the SwiftData-side dispatch
/// tables under `ProfileDataSyncHandler+SystemFields` mutate a fetched
/// `@Model` row in place via `record.encodedSystemFields = data`.
/// GRDB row structs (`CSVImportProfileRow`, `ImportRuleRow`)
/// **deliberately do not conform** — system-fields writes for those
/// record types route through `applyGRDBSystemFields(...)` and the
/// repository's `setEncodedSystemFieldsSync(id:data:)` SQL UPDATE
/// instead. The `buildCKRecord<T: ... & SystemFieldsCacheable>` upload
/// path constructs `CKRecord` values directly from the GRDB row's
/// `encodedSystemFields` snapshot inside the repo's `recordToSave`
/// helper, so it does not need protocol conformance to compile.
protocol SystemFieldsCacheable: AnyObject {
  var encodedSystemFields: Data? { get set }
}

extension AccountRecord: SystemFieldsCacheable {}
extension TransactionRecord: SystemFieldsCacheable {}
extension TransactionLegRecord: SystemFieldsCacheable {}
extension CategoryRecord: SystemFieldsCacheable {}
extension EarmarkRecord: SystemFieldsCacheable {}
extension EarmarkBudgetItemRecord: SystemFieldsCacheable {}
extension InvestmentValueRecord: SystemFieldsCacheable {}
extension InstrumentRecord: SystemFieldsCacheable {}
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
    ProfileRecord.recordType: ProfileRecord.self,
    InstrumentRecord.recordType: InstrumentRecord.self,
    AccountRecord.recordType: AccountRecord.self,
    TransactionRecord.recordType: TransactionRecord.self,
    TransactionLegRecord.recordType: TransactionLegRecord.self,
    CategoryRecord.recordType: CategoryRecord.self,
    EarmarkRecord.recordType: EarmarkRecord.self,
    EarmarkBudgetItemRecord.recordType: EarmarkBudgetItemRecord.self,
    InvestmentValueRecord.recordType: InvestmentValueRecord.self,
    // Slice 0 of `plans/grdb-migration.md` migrates these two record types
    // to GRDB. The CloudKit wire `recordType` strings are frozen contracts
    // and stay `"CSVImportProfileRecord"` / `"ImportRuleRecord"`; only the
    // local Swift type bound to each key changes.
    CSVImportProfileRow.recordType: CSVImportProfileRow.self,
    ImportRuleRow.recordType: ImportRuleRow.self,
  ]
}
