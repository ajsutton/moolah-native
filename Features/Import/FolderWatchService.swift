#if os(macOS)
  import CoreServices
  import Foundation
  import OSLog

  /// Live folder-watch service using FSEvents (macOS only). On iOS, the
  /// system doesn't grant a live background watch on a user folder, so
  /// `FolderScanService` runs on launch and scene-foreground instead.
  ///
  /// Lifecycle: `start()` resolves the security-scoped bookmark, opens an
  /// FSEvents stream, and forwards every `.csv` appearance / change to
  /// `ImportStore` via a delegating callback. `stop()` tears down the
  /// stream and releases the security-scoped resource.
  @MainActor
  final class FolderWatchService {

    private let importStore: ImportStore
    private let preferences: ImportPreferences
    private let scanner: FolderScanService
    private let fileManager: FileManager
    private let logger = Logger(
      subsystem: "com.moolah.app", category: "FolderWatchService")

    private var stream: FSEventStreamRef?
    private var watchedURL: URL?
    private var didStartAccess: Bool = false
    /// Held across the stream's lifetime and deallocated in `stop()` so the
    /// FSEventStreamContext isn't leaked when we drop the stream.
    private var contextPointer: UnsafeMutablePointer<FSEventStreamContext>?
    /// Tasks spawned by the FSEvents callback — tracked so `stop()` can
    /// cancel any in-flight `handleEvents` before the service is torn
    /// down, avoiding orphan ingests after the watch was explicitly
    /// stopped.
    private var inFlightTasks: [Task<Void, Never>] = []

    init(
      importStore: ImportStore,
      preferences: ImportPreferences,
      scanner: FolderScanService,
      fileManager: FileManager = .default
    ) {
      self.importStore = importStore
      self.preferences = preferences
      self.scanner = scanner
      self.fileManager = fileManager
    }

    /// Start watching. Runs a catch-up scan first (delegated to
    /// `FolderScanService`) so files added while the app was closed are
    /// picked up.
    func start() async {
      guard stream == nil else { return }
      await scanner.scanForNewFiles()
      guard let resolved = preferences.resolveWatchedFolder() else { return }
      watchedURL = resolved.url
      didStartAccess = resolved.startedAccess

      let context = UnsafeMutablePointer<FSEventStreamContext>.allocate(capacity: 1)
      context.initialize(
        to: FSEventStreamContext(
          version: 0,
          info: Unmanaged<FolderWatchService>.passUnretained(self).toOpaque(),
          retain: nil,
          release: nil,
          copyDescription: nil))

      let callback: FSEventStreamCallback = { _, info, count, pathsRaw, _, _ in
        guard let info else { return }
        let unmanaged = Unmanaged<FolderWatchService>.fromOpaque(info)
        let service = unmanaged.takeUnretainedValue()
        let cfArray = unsafeBitCast(pathsRaw, to: CFArray.self)
        let pathCount = CFArrayGetCount(cfArray)
        var paths: [String] = []
        paths.reserveCapacity(pathCount)
        for i in 0..<min(pathCount, count) {
          let ptr = CFArrayGetValueAtIndex(cfArray, i)
          if let ptr {
            let cfString = unsafeBitCast(ptr, to: CFString.self)
            paths.append(cfString as String)
          }
        }
        // `FSEventStreamSetDispatchQueue(newStream, .main)` (below) means
        // this callback fires on the main queue — but it's a C function
        // pointer with no actor isolation, so we still need the explicit
        // `Task { @MainActor in }` hop. Tracking the task lets `stop()`
        // cancel it if the watch is torn down mid-ingest.
        let task: Task<Void, Never> = Task { @MainActor in
          await service.handleEvents(paths: paths)
        }
        Task { @MainActor in
          service.inFlightTasks.append(task)
          await task.value
          service.inFlightTasks.removeAll { $0.isCancelled }
        }
      }

      let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
      guard
        let newStream = FSEventStreamCreate(
          kCFAllocatorDefault,
          callback,
          context,
          [resolved.url.path] as CFArray,
          FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
          1.0,
          flags)
      else {
        context.deinitialize(count: 1)
        context.deallocate()
        logger.error("FSEventStreamCreate failed")
        return
      }
      stream = newStream
      contextPointer = context
      FSEventStreamSetDispatchQueue(newStream, .main)
      FSEventStreamStart(newStream)
      let folderPath = resolved.url.path
      logger.info("Watching \(folderPath, privacy: .public) via FSEvents")
    }

    /// Stop watching and release the security-scoped resource.
    func stop() {
      if let stream {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
      }
      stream = nil
      if let contextPointer {
        contextPointer.deinitialize(count: 1)
        contextPointer.deallocate()
      }
      contextPointer = nil
      // Cancel any in-flight handle-events tasks so no ingest kicks off
      // after the watch has been torn down.
      for task in inFlightTasks { task.cancel() }
      inFlightTasks.removeAll()
      if didStartAccess, let watchedURL {
        watchedURL.stopAccessingSecurityScopedResource()
      }
      watchedURL = nil
      didStartAccess = false
    }

    // MARK: - Event handling

    private func handleEvents(paths: [String]) async {
      for path in paths {
        if Task.isCancelled { return }
        let url = URL(fileURLWithPath: path)
        guard url.pathExtension.lowercased() == "csv" else { continue }
        guard fileManager.fileExists(atPath: url.path) else { continue }
        guard let data = try? Data(contentsOf: url) else { continue }
        _ = await importStore.ingest(
          data: data,
          source: .folderWatch(url: url, bookmark: preferences.watchedFolderBookmark))
      }
    }
  }
#else
  // iOS — no live watch. `FolderScanService` handles launch / foreground
  // polls. This empty shim keeps call sites compiling.
  import Foundation

  @MainActor
  final class FolderWatchService {
    init(
      importStore: ImportStore,
      preferences: ImportPreferences,
      scanner: FolderScanService,
      fileManager: FileManager = .default
    ) {
      _ = importStore
      _ = preferences
      _ = scanner
      _ = fileManager
    }

    func start() async {}
    func stop() {}
  }
#endif
