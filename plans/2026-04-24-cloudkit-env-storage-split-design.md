# CloudKit Environment / Storage Split — Design

## Background

CloudKit routes each app build to one of two server environments — **Development** or **Production** — based on the code‑signing context and (optionally) the `com.apple.developer.icloud-container-environment` entitlement. Token state held by `CKSyncEngine` (server change tokens, per‑zone change tokens, pending record changes) and the CK `systemFields` baked into each SwiftData row are valid only against the environment they were negotiated with.

Today the Moolah app:

- Does **not** declare `com.apple.developer.icloud-container-environment`, so CloudKit falls back to code‑signing inference: developer‑signed builds (Xcode Debug, and currently `just install-mac`) hit **Development**; only distribution‑signed TestFlight/App Store builds hit **Production**.
- Keeps *all* on‑disk state that is tied to a CloudKit container at the Application‑Support root:
  - `~/Library/Application Support/Moolah-v2.store` (profile index)
  - `~/Library/Application Support/Moolah-<uuid>.store` (per‑profile SwiftData)
  - `~/Library/Application Support/Moolah-<uuid>.syncstate` (per‑profile sync state)
  - `~/Library/Application Support/` sibling files for `SyncCoordinator` serialisation
  - `~/Library/Application Support/Moolah/Backups/<uuid>/…` (nightly SwiftData snapshots)

The combination is unsafe. If the same Mac ever runs two builds that resolve to different CloudKit environments — e.g. a Debug Xcode run and a TestFlight / App Store / Developer‑ID install — they read and write the same tokens and system fields against different servers. Symptoms: phantom records, silent sync drops, `unknown record` errors, corrupted backups being restored into the wrong environment.

`just install-mac` is intended to mimic outside‑App‑Store distribution (Developer ID signing + notarisation) for the primary macOS channel. The owner wants that binary, once installed into `/Applications`, to hit **Production** CloudKit and to keep its on‑disk state strictly separate from any developer build of the same bundle ID running from Xcode.

## Goal

1. The CloudKit environment each build targets is pinned explicitly and deterministically from `project.yml`, not inferred from the signing context.
2. `just install-mac` targets **Production** CloudKit. Every other local build (Xcode Debug, `just test`, UI tests) targets **Development** (or runs without iCloud entitlements).
3. All on‑disk state tied to a CloudKit container (SwiftData stores, sync state files, `SyncCoordinator` serialisations, nightly backups) is scoped to an environment‑specific subdirectory. Under no circumstances can a build signed for one environment read or write state produced by a build signed for the other.
4. A developer running Xcode Debug on the same Mac that has `/Applications/Moolah.app` installed can use both without cross‑contamination.
5. Misconfiguration (missing or unexpected `MoolahCloudKitEnvironment` Info.plist value) aborts the process at launch rather than silently selecting a default.

### Acceptance criteria

- `codesign -d --entitlements :- /Applications/Moolah.app` after `just install-mac` contains `com.apple.developer.icloud-container-environment = Production`.
- The Xcode Debug build (with `ENABLE_ENTITLEMENTS=1 just generate`) signs with `com.apple.developer.icloud-container-environment = Development`.
- `just test` and `just test-mac` still pass with no iCloud entitlement on the test host (Debug‑Tests unchanged on the entitlements front).
- On first launch after the change:
  - `just install-mac` → Production build creates and uses `~/Library/Application Support/Production/…`. The Development subtree, if present, is untouched.
  - Xcode Debug → Development build creates and uses `~/Library/Application Support/Development/…`. The Production subtree, if present, is untouched.
  - Any existing files at the Application Support root (`Moolah-v2.store`, `Moolah-<uuid>.store`, `Moolah-<uuid>.syncstate`, `Moolah/Backups/…`) remain untouched — no migration, no deletion.
- Launching a build whose embedded `MoolahCloudKitEnvironment` is absent, empty, or not one of `Development` / `Production` calls `fatalError(_:)` with a message that names the Info.plist key.

## Non‑goals

- Automated migration of existing root‑level stores into an environment subdirectory. The owner will handle that by hand if/when needed.
- Touching `fastlane` / TestFlight / App Store pipelines beyond adding the new entitlement key. (Distribution builds already resolve to Production CloudKit today; the entitlement just makes that explicit.)
- Changing `CODE_SIGN_IDENTITY` defaults. The owner's local `.env` in the main checkout already overrides automatic signing for `just install-mac` with a Developer ID profile. This design assumes that override stays in place.
- Introducing a third environment (`Staging`, `Test`). Apple only supports `Development` and `Production`; Debug‑Tests uses `Development` as an inert value (it never reaches iCloud because it has no entitlement and runs in‑memory).
- A debug UI or log line surfacing legacy root‑level files. Owner confirmed: silent is fine.

## Design

### Source of truth: a per‑configuration build setting

Add `CLOUDKIT_ENVIRONMENT` to each configuration block in `project.yml`:

| Configuration | `CLOUDKIT_ENVIRONMENT` | Notes |
|---|---|---|
| `Debug` | `Development` | Xcode dev runs (with or without `ENABLE_ENTITLEMENTS=1`). |
| `Debug-Tests` | `Development` | Value is never read — test host has no iCloud entitlement and uses in‑memory `ModelContainer`. Set only so Info.plist expansion yields a literal string rather than the unexpanded variable. |
| `Release` | `Production` | Feeds both `just install-mac` (Developer ID signed) and any future fastlane / TestFlight / App Store distribution. |

Xcode build variable expansion then drives both the entitlement and the Info.plist at codesign / bundle time:

- **Entitlements plist** (`.build/Moolah.entitlements` via `scripts/inject-entitlements.sh`, and `fastlane/Moolah.entitlements` for distribution):

  ```xml
  <key>com.apple.developer.icloud-container-environment</key>
  <string>$(CLOUDKIT_ENVIRONMENT)</string>
  ```

  Xcode's entitlements preprocessing expands `$(CLOUDKIT_ENVIRONMENT)` using the target's active configuration at sign time. A Release build signs with `Production`; a Debug build signs with `Development`. Debug‑Tests doesn't get this entitlements file at all (see `scripts/inject-entitlements.sh`), so it remains iCloud‑free.

- **Info.plist** (`App/Info-iOS.plist` and `App/Info-macOS.plist`, both referenced by `project.yml`'s `INFOPLIST_FILE` setting): add

  ```xml
  <key>MoolahCloudKitEnvironment</key>
  <string>$(CLOUDKIT_ENVIRONMENT)</string>
  ```

  Xcode's `INFOPLIST_EXPAND_BUILD_SETTINGS` (default YES) expands `$(CLOUDKIT_ENVIRONMENT)` using the active configuration at bundle time, in the same way existing keys in these plists (`$(EXECUTABLE_NAME)`, `$(PRODUCT_NAME)`, etc.) are already expanded. This value is what Swift code reads at runtime to decide the storage subdirectory.

Because both the entitlement and the Info.plist derive from the same `CLOUDKIT_ENVIRONMENT` build setting, they cannot drift.

### Runtime resolver

New Swift type in `Shared/`:

```swift
/// The CloudKit environment the current build is signed for, as declared in
/// Info.plist. Resolves once at launch and is the single source of truth for
/// any code that must separate state between Development and Production
/// CloudKit containers.
enum CloudKitEnvironment: String, Sendable {
  case development = "Development"
  case production = "Production"

  /// The `Moolah/Application Support` subdirectory this environment writes to.
  var storageSubdirectory: String { rawValue }

  /// Resolves from `Bundle.main`'s `MoolahCloudKitEnvironment` Info.plist key.
  /// Calls `fatalError` if the key is missing, empty, or not one of the
  /// recognised values — the invariant "dev builds never write to production
  /// state" depends on this being unambiguous at launch.
  static func resolved() -> CloudKitEnvironment { … }
}
```

`resolved()` reads `Bundle.main.object(forInfoDictionaryKey: "MoolahCloudKitEnvironment")`, coerces to `String`, and matches the raw value. Any deviation (nil, non‑string, unknown string) calls `fatalError` with a message that names the Info.plist key so the cause is obvious from the crash log.

The value is resolved lazily on first access and cached for the process lifetime via a `static let` on `CloudKitEnvironment`. This makes misconfiguration fatal at the first call site rather than silently deferred.

### Storage helper

A single `URL` extension in `Shared/` replaces every production call site that reaches for `URL.applicationSupportDirectory` for CloudKit‑related state:

```swift
extension URL {
  /// Application Support, scoped to the current CloudKit environment.
  /// Use for any on-disk state tied to a CloudKit container: SwiftData stores,
  /// sync-state files, CKSyncEngine serialisations, nightly backups.
  /// Creates the subdirectory on demand.
  static var moolahEnvironmentScopedApplicationSupport: URL { … }
}
```

The helper appends `CloudKitEnvironment.resolved().storageSubdirectory` to `URL.applicationSupportDirectory` and ensures the directory exists (creating intermediate directories if needed). `StoreBackupManager` and the tests that inject a custom `backupDirectory` keep their existing injection seam — only the default value changes.

### File‑by‑file change surface

Production code:

- `project.yml` — add `CLOUDKIT_ENVIRONMENT` per configuration (`Debug` / `Debug-Tests` → `Development`, `Release` → `Production`) for both `Moolah_iOS` and `Moolah_macOS` targets.
- `App/Info-iOS.plist`, `App/Info-macOS.plist` — add `MoolahCloudKitEnvironment` key with value `$(CLOUDKIT_ENVIRONMENT)`.
- `scripts/inject-entitlements.sh` — extend the entitlements plist to include `com.apple.developer.icloud-container-environment = $(CLOUDKIT_ENVIRONMENT)`.
- `fastlane/Moolah.entitlements` — add the same entitlement key, value `$(CLOUDKIT_ENVIRONMENT)`. (Distribution builds already target Production; this makes it explicit and matches the in‑tree entitlements file.)
- `Shared/CloudKitEnvironment.swift` *(new)* — the resolver above.
- `Shared/URL+MoolahStorage.swift` *(new)* — the storage helper above. Internal test‑only override seam for swapping the Application Support root.
- `Shared/ProfileContainerManager.swift` — replace `URL.applicationSupportDirectory` at lines 34, 56, 65 with the scoped helper.
- `App/MoolahApp+Setup.swift` — replace at line 48 (`Moolah-v2.store`).
- `Backends/CloudKit/Sync/SyncCoordinator.swift` — replace at line 183 (`stateFileURL`).
- `App/ProfileSession.swift` — replace at line 231 (Application Support directory existence check).
- `Shared/StoreBackupManager.swift` — change default `backupDirectory` at line 20 to the scoped helper.

Test code:

- `MoolahTests/Shared/CloudKitEnvironmentTests.swift` *(new)* — covers the happy path of the resolver against a synthetic bundle, plus `storageSubdirectory` mapping. Fatal paths are verified by code review + Info.plist wiring, not unit tested (XCTest can't safely assert on `fatalError`).
- `MoolahTests/Shared/ProfileContainerManagerScopedStorageTests.swift` *(new)* — a file‑system smoke test that asserts a non‑in‑memory `ProfileContainerManager` writes into `<scoped root>/Moolah-<uuid>.store` using a test‑scoped override of the Application Support root.
- Existing `ProfileContainerManager.forTesting()` tests are unchanged: they use `inMemory: true` and never touch the scoped helper.

No UI test changes expected — UI tests already run with the `Debug-Tests`‑style iCloud‑free test host.

### On‑disk layout after the change

```
~/Library/Application Support/
├── Moolah-v2.store              ← orphaned legacy (untouched)
├── Moolah-<uuid>.store          ← orphaned legacy (untouched)
├── Moolah-<uuid>.syncstate      ← orphaned legacy (untouched)
├── Moolah/Backups/              ← orphaned legacy (untouched)
├── Development/
│   ├── Moolah-v2.store
│   ├── Moolah-<uuid>.store
│   ├── Moolah-<uuid>.syncstate
│   ├── SyncCoordinator state files
│   └── Moolah/Backups/<profileId>/…
└── Production/
    ├── Moolah-v2.store
    ├── Moolah-<uuid>.store
    ├── Moolah-<uuid>.syncstate
    ├── SyncCoordinator state files
    └── Moolah/Backups/<profileId>/…
```

Both subtrees only appear once their respective build has run at least once on the machine.

### Error handling / misconfiguration

One mode matters: the embedded `MoolahCloudKitEnvironment` is missing, empty, or unknown. `CloudKitEnvironment.resolved()` calls `fatalError(_:)` with a message of the form:

> `MoolahCloudKitEnvironment Info.plist key missing or invalid (got: "<raw>"). Expected "Development" or "Production". This build is misconfigured; refusing to start.`

Rationale: the alternative — falling back to a default — would make it possible for a build that *thinks* it's Development to write into Production's subdirectory, defeating the entire point of the split. Fatal at launch is consistent with the "dev builds never touch production data" invariant and is easy to diagnose from the crash log.

There is no Swift‑side check that the embedded environment matches the entitlement; they derive from the same `CLOUDKIT_ENVIRONMENT` build setting and cannot disagree without someone editing the built bundle by hand. The runtime check against Info.plist is sufficient.

## Testing

- **Unit**: `CloudKitEnvironmentTests` — resolver happy path for both values, `storageSubdirectory` mapping.
- **Integration**: `ProfileContainerManagerScopedStorageTests` — `ProfileContainerManager.container(for:)` on a non‑in‑memory instance, with the Application Support root overridden to a temp directory, writes `Moolah-<uuid>.store` under `<tmp>/Development/`.
- **Existing contract / store tests**: no change required. Tests build under `Debug-Tests`, the new `CLOUDKIT_ENVIRONMENT=Development` build setting feeds into the test host's Info.plist at build time, and the resolver returns `.development` — but the only code path that consumes it (`moolahEnvironmentScopedApplicationSupport`) isn't exercised by tests that use `inMemory: true` stores.
- **Manual verification** (one‑shot):
  1. `ENABLE_ENTITLEMENTS=1 just generate`, run from Xcode → confirm `~/Library/Application Support/Development/` populates; Production subtree is absent or untouched.
  2. `just install-mac`, launch `/Applications/Moolah.app` → confirm `~/Library/Application Support/Production/` populates; Development subtree untouched.
  3. `codesign -d --entitlements :- /Applications/Moolah.app` → confirm `com.apple.developer.icloud-container-environment = Production`.
  4. CloudKit dashboard → confirm records written by (1) appear in the Development container and records written by (2) appear in Production.

## Rollout

- Single PR. The build‑system changes and the runtime scoping are inseparable — landing one without the other either leaves `install-mac` pointing at Development CloudKit (no improvement) or writes Production state into the shared root (the corruption case we're preventing).
- Existing local stores at `~/Library/Application Support/Moolah-*.store` are left untouched. The owner handles any manual migration post‑merge; no code in this change touches those paths.
- No database schema change; no CloudKit schema change; no network‑side coordination required.
