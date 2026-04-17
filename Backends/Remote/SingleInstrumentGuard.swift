import Foundation

/// Throws `BackendError.unsupportedInstrument` when an entity's instrument
/// does not match the profile currency of a single-instrument backend
/// (Remote, moolah).
///
/// Defence in depth against a UI gating bug: the currency pickers are hidden
/// when `Profile.supportsComplexTransactions` is false (Remote / moolah),
/// so in correct use this guard never fires. If it does, a code path has
/// slipped past the gating — surface as an error rather than silently writing
/// data the backend cannot represent.
func requireMatchesProfileInstrument(
  _ instrument: Instrument,
  profile: Instrument,
  entity: String
) throws {
  guard instrument.id == profile.id else {
    throw BackendError.unsupportedInstrument(
      "\(entity) uses \(instrument.id); this backend only supports \(profile.id). "
        + "UI should gate on Profile.supportsComplexTransactions."
    )
  }
}
