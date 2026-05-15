// Backends/GRDB/Repositories/GRDBInstrumentRegistryRepository+InstrumentChangeObserving.swift

/// Conformance to the narrow `InstrumentChangeObserving` Domain seam.
///
/// The `@MainActor func observeChanges() -> AsyncStream<Void>`
/// requirement is already satisfied by the implementation in the main
/// `GRDBInstrumentRegistryRepository.swift` file (it also backs the
/// `InstrumentRegistryRepository.observeChanges()` requirement). This
/// extension only declares the additional conformance so per-profile
/// stores can depend on the minimal change-notification surface
/// without importing GRDB or the full registry repository protocol.
extension GRDBInstrumentRegistryRepository: InstrumentChangeObserving {}
