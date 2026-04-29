import Foundation

extension RawRepresentable where RawValue == String {
  /// Throwing alternative to `init?(rawValue:)`. Backend mappers use this
  /// when projecting persisted rows to domain values so that an unknown
  /// raw value (forward-incompatible schema, corruption) surfaces as
  /// `BackendError.dataCorrupted` rather than silently aliasing to a
  /// default case. Per `guides/DATABASE_CODE_GUIDE.md` §3.
  ///
  /// `label` defaults to `String(describing: Self.self)` (the unqualified
  /// enum name) and is included in the error message for diagnostic
  /// context. Pass an explicit label for nested types where the bare name
  /// (e.g. `"Kind"` for `Instrument.Kind`) would be ambiguous.
  static func decoded(rawValue: String, label: String? = nil) throws -> Self {
    guard let value = Self(rawValue: rawValue) else {
      let typeName = label ?? String(describing: Self.self)
      throw BackendError.dataCorrupted("Unknown \(typeName) raw value: \(rawValue)")
    }
    return value
  }
}
