# CloudKit Environment / Storage Split — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pin each build's CloudKit environment explicitly via a per‑configuration `CLOUDKIT_ENVIRONMENT` build setting, expose it in the entitlement and Info.plist, and scope every piece of on‑disk state tied to a CloudKit container into a `Development/` or `Production/` subdirectory of Application Support.

**Architecture:** Single source of truth — the `CLOUDKIT_ENVIRONMENT` build setting — drives both `com.apple.developer.icloud-container-environment` (entitlement) and `MoolahCloudKitEnvironment` (Info.plist). Swift code reads the Info.plist value through a new `CloudKitEnvironment` resolver and uses a `URL.moolahEnvironmentScopedApplicationSupport` helper for all CloudKit‑related on‑disk state. Missing or malformed Info.plist value aborts launch via `fatalError`.

**Tech Stack:** Swift 6, Swift Testing (`@Suite`, `@Test`, `#expect`), SwiftData, `xcodegen` (`just generate`). Build via `just build-mac`, test via `just test-mac`. Pre‑commit: `just format` then `just format-check`.

**Spec:** `plans/2026-04-24-cloudkit-env-storage-split-design.md`.

**Ordering rationale:** Build‑setting / Info.plist / entitlement wiring (Tasks 1–2) lands first and has no runtime effect. The Swift resolver and helper (Tasks 3–4) are introduced next with unit tests that don't read real bundles, so they also cause no launch‑time behaviour change. Only Tasks 5–9 switch production call sites to the helper — at which point the resolver reads the Info.plist key that was already wired in Task 1. This ordering means each intermediate commit is safe to run.

---

## Task 1: Wire `CLOUDKIT_ENVIRONMENT` build setting + `MoolahCloudKitEnvironment` Info.plist key

**Files:**
- Modify: `project.yml` (configs blocks for `Moolah_iOS` and `Moolah_macOS`)
- Modify: `App/Info-iOS.plist`
- Modify: `App/Info-macOS.plist`

- [ ] **Step 1: Add `CLOUDKIT_ENVIRONMENT` per configuration to `Moolah_iOS`**

  In `project.yml`, locate the `Moolah_iOS` target's `configs:` block (currently under `settings.configs:` around line 72). Replace:

  ```yaml
        configs:
          Debug-Tests:
            # Tests must never pick up iCloud entitlements, even when a dev
            # runs `ENABLE_ENTITLEMENTS=1 just generate` to inject them into Debug.
            CODE_SIGN_ENTITLEMENTS: ""
            SWIFT_ACTIVE_COMPILATION_CONDITIONS: "$(inherited)"
          Release:
            SWIFT_ACTIVE_COMPILATION_CONDITIONS: "$(inherited) CLOUDKIT_ENABLED"
  ```

  with:

  ```yaml
        configs:
          Debug:
            CLOUDKIT_ENVIRONMENT: Development
          Debug-Tests:
            # Tests must never pick up iCloud entitlements, even when a dev
            # runs `ENABLE_ENTITLEMENTS=1 just generate` to inject them into Debug.
            CODE_SIGN_ENTITLEMENTS: ""
            SWIFT_ACTIVE_COMPILATION_CONDITIONS: "$(inherited)"
            # Value is unused at runtime (test host has no iCloud entitlement
            # and uses in-memory stores) but must be defined so Info.plist
            # expansion yields a literal string rather than "$(CLOUDKIT_ENVIRONMENT)".
            CLOUDKIT_ENVIRONMENT: Development
          Release:
            SWIFT_ACTIVE_COMPILATION_CONDITIONS: "$(inherited) CLOUDKIT_ENABLED"
            CLOUDKIT_ENVIRONMENT: Production
  ```

- [ ] **Step 2: Add `CLOUDKIT_ENVIRONMENT` per configuration to `Moolah_macOS`**

  Same change in the `Moolah_macOS` target's `configs:` block (around line 103). The macOS Release block additionally has `ENABLE_HARDENED_RUNTIME: YES`; keep it. Final form:

  ```yaml
        configs:
          Debug:
            CLOUDKIT_ENVIRONMENT: Development
          Debug-Tests:
            CODE_SIGN_ENTITLEMENTS: ""
            SWIFT_ACTIVE_COMPILATION_CONDITIONS: "$(inherited)"
            CLOUDKIT_ENVIRONMENT: Development
          Release:
            ENABLE_HARDENED_RUNTIME: YES
            SWIFT_ACTIVE_COMPILATION_CONDITIONS: "$(inherited) CLOUDKIT_ENABLED"
            CLOUDKIT_ENVIRONMENT: Production
  ```

- [ ] **Step 3: Add `MoolahCloudKitEnvironment` key to `App/Info-iOS.plist`**

  Insert immediately before the closing `</dict>` of the top-level dictionary:

  ```xml
  	<key>MoolahCloudKitEnvironment</key>
  	<string>$(CLOUDKIT_ENVIRONMENT)</string>
  ```

- [ ] **Step 4: Add `MoolahCloudKitEnvironment` key to `App/Info-macOS.plist`**

  Insert the same two lines in `App/Info-macOS.plist` immediately before the closing `</dict>` of the top-level dictionary.

- [ ] **Step 5: Regenerate Xcode project**

  ```bash
  just generate
  ```

  Expected: completes without error; no diff in `Moolah.xcodeproj` tracked state (the project is gitignored).

- [ ] **Step 6: Verify the build setting is defined for each configuration**

  ```bash
  xcodebuild -showBuildSettings -project Moolah.xcodeproj -target Moolah_macOS -configuration Release 2>/dev/null | grep -E "^\s*CLOUDKIT_ENVIRONMENT = "
  xcodebuild -showBuildSettings -project Moolah.xcodeproj -target Moolah_macOS -configuration Debug 2>/dev/null | grep -E "^\s*CLOUDKIT_ENVIRONMENT = "
  xcodebuild -showBuildSettings -project Moolah.xcodeproj -target Moolah_macOS -configuration Debug-Tests 2>/dev/null | grep -E "^\s*CLOUDKIT_ENVIRONMENT = "
  ```

  Expected output (one line per command):

  ```
      CLOUDKIT_ENVIRONMENT = Production
      CLOUDKIT_ENVIRONMENT = Development
      CLOUDKIT_ENVIRONMENT = Development
  ```

- [ ] **Step 7: Build macOS and verify Info.plist expansion**

  ```bash
  just build-mac 2>&1 | tail -5
  /usr/libexec/PlistBuddy -c "Print :MoolahCloudKitEnvironment" build/Build/Products/Debug/Moolah.app/Contents/Info.plist
  ```

  Expected: build succeeds; second command prints `Development`.

- [ ] **Step 8: Commit**

  ```bash
  git add project.yml App/Info-iOS.plist App/Info-macOS.plist
  git commit -m "build: declare CLOUDKIT_ENVIRONMENT per configuration"
  ```

---

## Task 2: Declare `com.apple.developer.icloud-container-environment` in both entitlement sources

**Files:**
- Modify: `scripts/inject-entitlements.sh` (heredoc writing `.build/Moolah.entitlements`)
- Modify: `fastlane/Moolah.entitlements`

- [ ] **Step 1: Extend the entitlements heredoc in `scripts/inject-entitlements.sh`**

  Replace the current heredoc body (lines 25–46, the `PLIST` heredoc) with the version that adds one new key:

  ```bash
  cat > "$ENTITLEMENTS_FILE" <<'PLIST'
  <?xml version="1.0" encoding="UTF-8"?>
  <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
  <plist version="1.0">
  <dict>
      <key>com.apple.security.app-sandbox</key>
      <true/>
      <key>com.apple.security.network.client</key>
      <true/>
      <key>com.apple.security.files.user-selected.read-write</key>
      <true/>
      <key>com.apple.developer.icloud-services</key>
      <array>
          <string>CloudKit</string>
      </array>
      <key>com.apple.developer.icloud-container-identifiers</key>
      <array>
          <string>iCloud.rocks.moolah.app.v2</string>
      </array>
      <key>com.apple.developer.icloud-container-environment</key>
      <string>$(CLOUDKIT_ENVIRONMENT)</string>
  </dict>
  </plist>
  PLIST
  ```

  The `$(CLOUDKIT_ENVIRONMENT)` token is a build variable, not a shell variable: the single‑quoted heredoc (`<<'PLIST'`) preserves it literally so Xcode's entitlements preprocessing expands it at codesign time.

- [ ] **Step 2: Extend `fastlane/Moolah.entitlements`**

  Replace its contents with:

  ```xml
  <?xml version="1.0" encoding="UTF-8"?>
  <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
  <plist version="1.0">
  <dict>
    <key>com.apple.developer.icloud-container-identifiers</key>
    <array><string>iCloud.rocks.moolah.app.v2</string></array>
    <key>com.apple.developer.icloud-services</key>
    <array><string>CloudKit</string></array>
    <key>com.apple.developer.icloud-container-environment</key>
    <string>$(CLOUDKIT_ENVIRONMENT)</string>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
  </dict>
  </plist>
  ```

- [ ] **Step 3: Regenerate with entitlements and verify the script's output plist**

  ```bash
  ENABLE_ENTITLEMENTS=1 just generate
  /usr/libexec/PlistBuddy -c "Print :com.apple.developer.icloud-container-environment" .build/Moolah.entitlements
  ```

  Expected: second command prints `$(CLOUDKIT_ENVIRONMENT)` literally (the token is expanded later, at codesign time — not here).

- [ ] **Step 4: Build and verify the signed binary's entitlements**

  ```bash
  ENABLE_ENTITLEMENTS=1 just generate
  xcodebuild build -scheme Moolah-macOS -destination 'platform=macOS' -configuration Debug -derivedDataPath .build-debug 2>&1 | tail -5
  codesign -d --entitlements :- .build-debug/Build/Products/Debug/Moolah.app 2>/dev/null | grep -A1 "icloud-container-environment"
  ```

  Expected: last command prints an element whose string value is `Development`.

  Clean up: `rm -rf .build-debug`.

- [ ] **Step 5: Commit**

  ```bash
  git add scripts/inject-entitlements.sh fastlane/Moolah.entitlements
  git commit -m "build: declare iCloud container environment in entitlements"
  ```

---

## Task 3: Add `CloudKitEnvironment` resolver (TDD)

**Files:**
- Create: `Shared/CloudKitEnvironment.swift`
- Create: `MoolahTests/Shared/CloudKitEnvironmentTests.swift`

- [ ] **Step 1: Write the failing tests**

  Create `MoolahTests/Shared/CloudKitEnvironmentTests.swift`:

  ```swift
  import Foundation
  import Testing

  @testable import Moolah

  @Suite("CloudKitEnvironment")
  struct CloudKitEnvironmentTests {
    @Test("resolves Development from raw value")
    func testResolveDevelopment() {
      let env = CloudKitEnvironment.resolve(from: "Development")
      #expect(env == .development)
    }

    @Test("resolves Production from raw value")
    func testResolveProduction() {
      let env = CloudKitEnvironment.resolve(from: "Production")
      #expect(env == .production)
    }

    @Test("storageSubdirectory matches raw value")
    func testStorageSubdirectory() {
      #expect(CloudKitEnvironment.development.storageSubdirectory == "Development")
      #expect(CloudKitEnvironment.production.storageSubdirectory == "Production")
    }
  }
  ```

- [ ] **Step 2: Run the test and confirm it fails to compile**

  ```bash
  mkdir -p .agent-tmp
  just test-mac CloudKitEnvironmentTests 2>&1 | tee .agent-tmp/test-output.txt | tail -20
  ```

  Expected: compile error referencing missing `CloudKitEnvironment`.

- [ ] **Step 3: Create the resolver**

  Create `Shared/CloudKitEnvironment.swift`:

  ```swift
  import Foundation

  /// The CloudKit environment this build is signed for, as declared in
  /// Info.plist. Resolves once at launch and is the single source of truth for
  /// any code that must separate on-disk state between Development and
  /// Production CloudKit containers.
  enum CloudKitEnvironment: String, Sendable {
    case development = "Development"
    case production = "Production"

    /// Name of the subdirectory under Application Support that this environment
    /// writes to. Equal to the raw value.
    var storageSubdirectory: String { rawValue }

    private static let cached: CloudKitEnvironment = {
      resolve(from: Bundle.main.object(forInfoDictionaryKey: Self.infoPlistKey))
    }()

    /// The CloudKit environment the running process is signed for. Resolves
    /// from `Bundle.main`'s `MoolahCloudKitEnvironment` Info.plist key once
    /// per process. Aborts the process via `fatalError` if the key is missing
    /// or does not match a known environment.
    static func resolved() -> CloudKitEnvironment { cached }

    /// Testable form of the resolver. Production code uses `resolved()`.
    static func resolve(from value: Any?) -> CloudKitEnvironment {
      guard let raw = value as? String, let env = CloudKitEnvironment(rawValue: raw) else {
        fatalError(
          """
          \(infoPlistKey) Info.plist key missing or invalid (got: \
          \(String(describing: value))). Expected "Development" or "Production". \
          This build is misconfigured; refusing to start.
          """
        )
      }
      return env
    }

    static let infoPlistKey = "MoolahCloudKitEnvironment"
  }
  ```

- [ ] **Step 4: Run the tests and confirm they pass**

  ```bash
  just test-mac CloudKitEnvironmentTests 2>&1 | tee .agent-tmp/test-output.txt | tail -20
  ```

  Expected: 3 tests passing.

- [ ] **Step 5: Format and commit**

  ```bash
  just format
  just format-check
  git add Shared/CloudKitEnvironment.swift MoolahTests/Shared/CloudKitEnvironmentTests.swift
  git commit -m "feat(cloudkit): add CloudKitEnvironment resolver"
  rm -f .agent-tmp/test-output.txt
  ```

  `MoolahTests/Shared/` is new — `xcodegen` picks it up automatically via the target's `- path: MoolahTests` source entry. Regenerate if Xcode complains:

  ```bash
  just generate
  ```

---

## Task 4: Add `URL.moolahEnvironmentScopedApplicationSupport` helper + test override (TDD)

**Files:**
- Create: `Shared/URL+MoolahStorage.swift`
- Create: `MoolahTests/Shared/URLMoolahStorageTests.swift`

- [ ] **Step 1: Write the failing tests**

  Create `MoolahTests/Shared/URLMoolahStorageTests.swift`:

  ```swift
  import Foundation
  import Testing

  @testable import Moolah

  @Suite("URL+MoolahStorage")
  struct URLMoolahStorageTests {
    @Test("returns <root>/<env>/ with env subdir created")
    func testScopedRootUsesEnvironmentSubdirectory() throws {
      let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }

      URL.moolahApplicationSupportOverride = root
      defer { URL.moolahApplicationSupportOverride = nil }

      let scoped = URL.moolahEnvironmentScopedApplicationSupport

      let expected = root.appending(path: CloudKitEnvironment.resolved().storageSubdirectory)
      #expect(scoped.standardizedFileURL == expected.standardizedFileURL)
      #expect(FileManager.default.fileExists(atPath: scoped.path()))
    }

    @Test("falls back to Application Support when no override is set")
    func testScopedRootDefaultsToApplicationSupport() {
      URL.moolahApplicationSupportOverride = nil
      let scoped = URL.moolahEnvironmentScopedApplicationSupport
      let expectedPrefix = URL.applicationSupportDirectory
        .appending(path: CloudKitEnvironment.resolved().storageSubdirectory)
      #expect(scoped.standardizedFileURL == expectedPrefix.standardizedFileURL)
    }
  }
  ```

- [ ] **Step 2: Run and confirm it fails to compile**

  ```bash
  just test-mac URLMoolahStorageTests 2>&1 | tee .agent-tmp/test-output.txt | tail -20
  ```

  Expected: compile error for missing `moolahApplicationSupportOverride` and `moolahEnvironmentScopedApplicationSupport`.

- [ ] **Step 3: Create the helper**

  Create `Shared/URL+MoolahStorage.swift`:

  ```swift
  import Foundation

  extension URL {
    /// Test-only override for the Application Support root. Production code
    /// should leave this `nil`; tests set it to a temporary directory and reset
    /// it in a defer block.
    nonisolated(unsafe) static var moolahApplicationSupportOverride: URL?

    /// Application Support, scoped to the current CloudKit environment.
    ///
    /// Use this for any on-disk state tied to a CloudKit container: SwiftData
    /// stores, sync-state files, `CKSyncEngine` serialisations, nightly
    /// backups. The subdirectory is created on demand so callers never need to
    /// guard on its existence.
    static var moolahEnvironmentScopedApplicationSupport: URL {
      let root = moolahApplicationSupportOverride ?? URL.applicationSupportDirectory
      let scoped = root.appending(path: CloudKitEnvironment.resolved().storageSubdirectory)
      try? FileManager.default.createDirectory(at: scoped, withIntermediateDirectories: true)
      return scoped
    }
  }
  ```

- [ ] **Step 4: Run the tests and confirm they pass**

  ```bash
  just test-mac URLMoolahStorageTests 2>&1 | tee .agent-tmp/test-output.txt | tail -20
  ```

  Expected: 2 tests passing.

- [ ] **Step 5: Format and commit**

  ```bash
  just format
  just format-check
  git add Shared/URL+MoolahStorage.swift MoolahTests/Shared/URLMoolahStorageTests.swift
  git commit -m "feat(cloudkit): add environment-scoped Application Support helper"
  rm -f .agent-tmp/test-output.txt
  ```

---

## Task 5: Route `ProfileContainerManager` through the scoped helper (TDD)

**Files:**
- Modify: `Shared/ProfileContainerManager.swift` (lines 34, 56, 65)
- Modify: `MoolahTests/App/ProfileContainerManagerTests.swift` (add one new test)

- [ ] **Step 1: Add the failing test**

  Append inside `MoolahTests/App/ProfileContainerManagerTests.swift`'s `ProfileContainerManagerTests` struct (after `testDeleteStore`):

  ```swift
    @Test("configures per-profile store URL under the scoped Application Support root")
    @MainActor
    func testContainerUsesScopedStoreURL() throws {
      let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }

      URL.moolahApplicationSupportOverride = root
      defer { URL.moolahApplicationSupportOverride = nil }

      let indexSchema = Schema([ProfileRecord.self])
      let indexConfig = ModelConfiguration(isStoredInMemoryOnly: true)
      let indexContainer = try ModelContainer(for: indexSchema, configurations: [indexConfig])
      let dataSchema = Schema([
        AccountRecord.self,
        TransactionRecord.self,
        TransactionLegRecord.self,
        InstrumentRecord.self,
        CategoryRecord.self,
        EarmarkRecord.self,
        EarmarkBudgetItemRecord.self,
        InvestmentValueRecord.self,
        CSVImportProfileRecord.self,
        ImportRuleRecord.self,
      ])

      let manager = ProfileContainerManager(
        indexContainer: indexContainer,
        dataSchema: dataSchema,
        inMemory: false
      )

      let profileId = UUID()
      let container = try manager.container(for: profileId)

      let envSubdir = CloudKitEnvironment.resolved().storageSubdirectory
      let expectedStore = root
        .appending(path: envSubdir)
        .appending(path: "Moolah-\(profileId.uuidString).store")
      let actualURL = container.configurations.first?.url
      #expect(actualURL?.standardizedFileURL == expectedStore.standardizedFileURL)

      // Env subdir must have been created on demand by the scoped helper.
      let envDir = root.appending(path: envSubdir)
      #expect(FileManager.default.fileExists(atPath: envDir.path()))
    }
  ```

  (Asserting on `container.configurations.first?.url` rather than checking for the `.store` file on disk keeps the test deterministic — SwiftData may lazily materialise the store file until the first fetch / save.)

- [ ] **Step 2: Run the test and confirm it fails**

  ```bash
  just test-mac ProfileContainerManagerTests/testContainerUsesScopedStoreURL 2>&1 | tee .agent-tmp/test-output.txt | tail -20
  ```

  Expected: failure — `container.configurations.first?.url` still points at the real `URL.applicationSupportDirectory`'s `Moolah-<uuid>.store`, which won't equal `<root>/<env>/Moolah-<uuid>.store`.

- [ ] **Step 3: Replace the three `URL.applicationSupportDirectory` call sites in `ProfileContainerManager`**

  In `Shared/ProfileContainerManager.swift`:

  Line 33–36 (inside `container(for:)`), replace:

  ```swift
        let storeName = "Moolah-\(profileId.uuidString)"
        let url = URL.applicationSupportDirectory
          .appending(path: "Moolah-\(profileId.uuidString).store")
        config = ModelConfiguration(storeName, url: url, cloudKitDatabase: .none)
  ```

  with:

  ```swift
        let storeName = "Moolah-\(profileId.uuidString)"
        let url = URL.moolahEnvironmentScopedApplicationSupport
          .appending(path: "Moolah-\(profileId.uuidString).store")
        config = ModelConfiguration(storeName, url: url, cloudKitDatabase: .none)
  ```

  Line 55–56 (inside `deleteStore(for:)`), replace:

  ```swift
      let basePath = "Moolah-\(profileId.uuidString).store"
      let baseURL = URL.applicationSupportDirectory.appending(path: basePath)
  ```

  with:

  ```swift
      let basePath = "Moolah-\(profileId.uuidString).store"
      let baseURL = URL.moolahEnvironmentScopedApplicationSupport.appending(path: basePath)
  ```

  Line 64–66 (also inside `deleteStore(for:)`), replace:

  ```swift
      // Delete the sync state file
      let syncStateURL = URL.applicationSupportDirectory
        .appending(path: "Moolah-\(profileId.uuidString).syncstate")
  ```

  with:

  ```swift
      // Delete the sync state file
      let syncStateURL = URL.moolahEnvironmentScopedApplicationSupport
        .appending(path: "Moolah-\(profileId.uuidString).syncstate")
  ```

- [ ] **Step 4: Run the new test and confirm it passes**

  ```bash
  just test-mac ProfileContainerManagerTests/testContainerUsesScopedStoreURL 2>&1 | tee .agent-tmp/test-output.txt | tail -20
  ```

  Expected: PASS.

- [ ] **Step 5: Run the full `ProfileContainerManagerTests` suite to confirm no regressions**

  ```bash
  just test-mac ProfileContainerManagerTests 2>&1 | tee .agent-tmp/test-output.txt | tail -20
  ```

  Expected: all tests passing.

- [ ] **Step 6: Format and commit**

  ```bash
  just format
  just format-check
  git add Shared/ProfileContainerManager.swift MoolahTests/App/ProfileContainerManagerTests.swift
  git commit -m "refactor(profiles): scope per-profile stores by CloudKit environment"
  rm -f .agent-tmp/test-output.txt
  ```

---

## Task 6: Scope the profile index store in `MoolahApp+Setup`

**Files:**
- Modify: `App/MoolahApp+Setup.swift:48`

- [ ] **Step 1: Replace the `URL.applicationSupportDirectory` call**

  Locate line 48 in `App/MoolahApp+Setup.swift`:

  ```swift
        let profileStoreURL = URL.applicationSupportDirectory.appending(path: "Moolah-v2.store")
  ```

  Replace with:

  ```swift
        let profileStoreURL = URL.moolahEnvironmentScopedApplicationSupport
          .appending(path: "Moolah-v2.store")
  ```

- [ ] **Step 2: Build and confirm the app compiles**

  ```bash
  just build-mac 2>&1 | tail -5
  ```

  Expected: succeeds with no warnings.

- [ ] **Step 3: Format and commit**

  ```bash
  just format
  just format-check
  git add App/MoolahApp+Setup.swift
  git commit -m "refactor(profiles): scope profile index store by CloudKit environment"
  ```

---

## Task 7: Scope the `SyncCoordinator` state file

**Files:**
- Modify: `Backends/CloudKit/Sync/SyncCoordinator.swift:183-184`

- [ ] **Step 1: Replace the `stateFileURL` declaration**

  At lines 183–184 of `Backends/CloudKit/Sync/SyncCoordinator.swift`, replace:

  ```swift
    let stateFileURL = URL.applicationSupportDirectory
      .appending(path: "Moolah-v2-sync.syncstate")
  ```

  with:

  ```swift
    let stateFileURL = URL.moolahEnvironmentScopedApplicationSupport
      .appending(path: "Moolah-v2-sync.syncstate")
  ```

- [ ] **Step 3: Build and run the full CloudKit test suite**

  ```bash
  just test-mac CloudKit 2>&1 | tee .agent-tmp/test-output.txt | tail -20
  ```

  Expected: existing CloudKit tests continue to pass. They operate on synthetic zones / in-memory stores and should not be affected, but this catches any accidental cross-file impact.

- [ ] **Step 4: Format and commit**

  ```bash
  just format
  just format-check
  git add Backends/CloudKit/Sync/SyncCoordinator.swift
  git commit -m "refactor(sync): scope SyncCoordinator state file by CloudKit environment"
  rm -f .agent-tmp/test-output.txt
  ```

---

## Task 8: Scope `ProfileSession.importStagingDirectory(for:)`'s root

**Files:**
- Modify: `App/ProfileSession.swift:225-241` (the `importStagingDirectory(for:)` static function)

Context: `importStagingDirectory(for:)` returns `<ApplicationSupport>/Moolah/csv-staging/<profileId>/`. CSV staging is device‑local and doesn't itself sync, but it is keyed on a profile ID whose SwiftData store is env‑scoped, so the staging root has to move under the env subdirectory too. Otherwise a build signed for Production would reach into the same `Moolah/csv-staging/` tree that a Development build wrote, defeating the separation for anything that reads staged files after a profile switch.

- [ ] **Step 1: Replace the body of `importStagingDirectory(for:)`**

  Replace lines 228–241 (the whole function body) in `App/ProfileSession.swift`:

  ```swift
    nonisolated static func importStagingDirectory(for profileId: UUID) -> URL {
      let base =
        (try? FileManager.default.url(
          for: .applicationSupportDirectory,
          in: .userDomainMask,
          appropriateFor: nil,
          create: true))
        ?? FileManager.default.temporaryDirectory
      return
        base
        .appendingPathComponent("Moolah", isDirectory: true)
        .appendingPathComponent("csv-staging", isDirectory: true)
        .appendingPathComponent(profileId.uuidString, isDirectory: true)
    }
  ```

  with:

  ```swift
    nonisolated static func importStagingDirectory(for profileId: UUID) -> URL {
      URL.moolahEnvironmentScopedApplicationSupport
        .appendingPathComponent("Moolah", isDirectory: true)
        .appendingPathComponent("csv-staging", isDirectory: true)
        .appendingPathComponent(profileId.uuidString, isDirectory: true)
    }
  ```

  The fallback to `FileManager.default.temporaryDirectory` is dropped: the scoped helper already creates its directory on demand and doesn't throw. Losing that fallback is intentional — if Application Support is genuinely unwritable the app cannot function, so failing loudly on the subsequent file I/O is correct.

- [ ] **Step 2: Build**

  ```bash
  just build-mac 2>&1 | tail -5
  ```

  Expected: succeeds.

- [ ] **Step 3: Run the `ProfileSession`‑adjacent test suites**

  ```bash
  just test-mac ProfileSessionTests 2>&1 | tee .agent-tmp/test-output.txt | tail -20
  ```

  Expected: existing tests pass. If any import‑staging test asserts on the absolute path it may need updating to the env‑scoped form; inspect the failure and adjust the assertion to match `.../<env>/Moolah/csv-staging/<profileId>/`.

- [ ] **Step 4: Format and commit**

  ```bash
  just format
  just format-check
  git add App/ProfileSession.swift
  git commit -m "refactor(profiles): scope CSV import staging by CloudKit environment"
  rm -f .agent-tmp/test-output.txt
  ```

---

## Task 9: Scope the default `StoreBackupManager.backupDirectory` (TDD)

**Files:**
- Modify: `Shared/StoreBackupManager.swift:20`
- Create: `MoolahTests/Backup/StoreBackupManagerDefaultLocationTests.swift`

- [ ] **Step 1: Write the failing test**

  Create `MoolahTests/Backup/StoreBackupManagerDefaultLocationTests.swift`:

  ```swift
  #if os(macOS)
    import Foundation
    import Testing

    @testable import Moolah

    @Suite("StoreBackupManager default location")
    struct StoreBackupManagerDefaultLocationTests {
      @Test("default backup directory is scoped by CloudKit environment")
      @MainActor
      func testDefaultBackupDirectoryIsScoped() throws {
        let root = FileManager.default.temporaryDirectory
          .appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        URL.moolahApplicationSupportOverride = root
        defer { URL.moolahApplicationSupportOverride = nil }

        let manager = StoreBackupManager()

        let envSubdir = CloudKitEnvironment.resolved().storageSubdirectory
        let expected = root
          .appending(path: envSubdir)
          .appending(path: "Moolah/Backups")
        #expect(manager.testing_backupDirectory.standardizedFileURL == expected.standardizedFileURL)
      }
    }
  #endif
  ```

- [ ] **Step 2: Expose a test accessor on `StoreBackupManager`**

  At the bottom of `StoreBackupManager` (still inside the `#if os(macOS)` block), add:

  ```swift
      /// Test-only accessor for the configured backup directory. Read-only.
      var testing_backupDirectory: URL { backupDirectory }
  ```

- [ ] **Step 3: Run the test and confirm it fails**

  ```bash
  just test-mac StoreBackupManagerDefaultLocationTests 2>&1 | tee .agent-tmp/test-output.txt | tail -20
  ```

  Expected: fails because the default `backupDirectory` is still `URL.applicationSupportDirectory.appending(path: "Moolah/Backups")` — no env subdir.

- [ ] **Step 4: Scope the default**

  In `Shared/StoreBackupManager.swift`, replace line 20's default:

  ```swift
      init(
        backupDirectory: URL = URL.applicationSupportDirectory.appending(path: "Moolah/Backups"),
  ```

  with:

  ```swift
      init(
        backupDirectory: URL = URL.moolahEnvironmentScopedApplicationSupport
          .appending(path: "Moolah/Backups"),
  ```

- [ ] **Step 5: Run the test and confirm it passes**

  ```bash
  just test-mac StoreBackupManagerDefaultLocationTests 2>&1 | tee .agent-tmp/test-output.txt | tail -20
  ```

  Expected: passing.

- [ ] **Step 6: Run the full Backup test suite for regressions**

  ```bash
  just test-mac Backup 2>&1 | tee .agent-tmp/test-output.txt | tail -20
  ```

  Expected: all tests pass (existing tests inject their own `backupDirectory` and aren't affected).

- [ ] **Step 7: Format and commit**

  ```bash
  just format
  just format-check
  git add Shared/StoreBackupManager.swift MoolahTests/Backup/StoreBackupManagerDefaultLocationTests.swift
  git commit -m "refactor(backup): scope default backup directory by CloudKit environment"
  rm -f .agent-tmp/test-output.txt
  ```

---

## Task 10: Full‑suite regression + build sweep

- [ ] **Step 1: Run the complete test suite on macOS**

  ```bash
  just test-mac 2>&1 | tee .agent-tmp/test-output.txt | tail -30
  ```

  Expected: all tests pass.

- [ ] **Step 2: Run the iOS test suite**

  ```bash
  just test-ios 2>&1 | tee .agent-tmp/test-output.txt | tail -30
  ```

  Expected: all tests pass.

- [ ] **Step 3: Build the iOS target**

  ```bash
  just build-ios 2>&1 | tail -5
  ```

  Expected: succeeds without warnings.

- [ ] **Step 4: Verify no new navigator issues**

  Use Xcode MCP (`mcp__xcode__XcodeListNavigatorIssues`) with `severity: "warning"` to confirm zero warnings in user code.

- [ ] **Step 5: Clean up temp files**

  ```bash
  rm -f .agent-tmp/test-output.txt
  ```

---

## Task 11: Manual verification (owner‑run; plan records the procedure)

These steps are not automatable from this session — they require running real builds on the owner's Mac, with their local signing identity, against the real CloudKit containers. The implementation is not considered complete until they have been walked through.

- [ ] **Step 1: Verify Xcode Debug build signs for Development**

  ```bash
  ENABLE_ENTITLEMENTS=1 just generate
  ```

  Build and run from Xcode. After first launch, verify:

  - `~/Library/Application Support/Development/Moolah-v2.store` exists.
  - `~/Library/Application Support/Production/` is either absent or untouched.
  - `codesign -d --entitlements :- .build-debug/Build/Products/Debug/Moolah.app` (or equivalent path from Xcode's DerivedData) shows `com.apple.developer.icloud-container-environment = Development`.
  - CloudKit dashboard → records appear in the **Development** container.

- [ ] **Step 2: Verify `just install-mac` signs for Production**

  ```bash
  just install-mac
  open /Applications/Moolah.app
  ```

  After first launch, verify:

  - `~/Library/Application Support/Production/Moolah-v2.store` exists.
  - `~/Library/Application Support/Development/` is either absent or untouched.
  - `codesign -d --entitlements :- /Applications/Moolah.app` shows `com.apple.developer.icloud-container-environment = Production`.
  - CloudKit dashboard → records appear in the **Production** container.

- [ ] **Step 3: Verify coexistence**

  Run both builds (Xcode Debug → then `just install-mac` again) and confirm each reads its own environment's subdirectory without touching the other. Open the app from `/Applications` and confirm its data is independent of what Xcode Debug sees.

- [ ] **Step 4: Spot‑check legacy files are untouched**

  ```bash
  ls ~/Library/Application\ Support/ | grep -E "^Moolah-" || echo "(no root-level legacy stores)"
  ```

  Whatever is there should still be there, with the same mtimes, after both builds have run. No code in this change touches these paths.

---

## Rollback

If Task 11 reveals a misconfiguration that wasn't caught in Tasks 1–10, the fastest rollback is `git revert` on the Task 2 commit (entitlement declaration) and the Task 1 commit (build setting). Without those, the Swift code still falls back safely — but on launch the resolver will `fatalError` because Info.plist no longer contains the key. So rollback must revert Task 1's plist changes *alongside* reverting the code, or leave everything reverted. Do not leave the Swift helpers live with the Info.plist key absent.
