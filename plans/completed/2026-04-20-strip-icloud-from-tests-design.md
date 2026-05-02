# Strip iCloud Entitlements From Test Builds — Design

Resolves: [#206](https://github.com/ajsutton/moolah-native/issues/206).

## Background

The flaky `AnalysisRepositoryContractTests/holding revalues daily as exchange rate changes` failure was traced to the test process booting the real `SyncCoordinator` against the developer's iCloud account. Via SwiftData's shared process state, those records bled into the test's in-memory `ModelContainer` and surfaced as a ~3272.77 AUD phantom offset.

A first fix (commit `4194767`) added two runtime guards in `App/MoolahApp.swift` and `MoolahTests/Support/TestModelContainer.swift`:

- `SyncCoordinator.start()` is skipped when `NSClassFromString("XCTestCase") != nil`.
- The test container sets `cloudKitDatabase: .none` to block SwiftData automatic mirroring.

That made the tests pass, but left the structural hole open: the test host binary is still signed with iCloud entitlements when `ENABLE_ENTITLEMENTS=1` is set locally. Any new test that directly calls `CKContainer.default()` / `CKSyncEngine` would quietly succeed against real iCloud.

### How entitlements reach the test host today

Three build paths:

1. **Default (`ENABLE_ENTITLEMENTS=0`, CI and most local dev)** — committed `project.yml` contains no entitlements. `CLOUDKIT_ENABLED` is only set for the `Release` config. Test host has no iCloud capability. *Safe.*
2. **Local CloudKit dev (`ENABLE_ENTITLEMENTS=1`)** — `scripts/inject-entitlements.sh` writes a temporary `project-entitlements.yml` that (a) adds an `entitlements:` block with iCloud container + CloudKit services to each app target, applied across **every configuration**, and (b) adds `CLOUDKIT_ENABLED` to `settings.base`, again across every configuration. `just test` uses the Debug config, so it inherits both. *Leaks iCloud into tests.*
3. **`fastlane` distribution (TestFlight / validate)** — the `Fastfile` passes `CODE_SIGN_ENTITLEMENTS=fastlane/Moolah.entitlements` to the archive build. Tests are not executed. *Out of scope.*

Only path 2 is the target. But the fix must be structural enough that path 1 stays safe even if someone later commits iCloud entitlements directly into `project.yml`.

## Goal

Repeat from the issue:

1. The binary used as the test host must not be signed with any `iCloud.*` entitlement.
2. `CKContainer.default()` / `CKSyncEngine` calls from test code should fail cleanly rather than succeed silently against the developer's iCloud.

And the acceptance criteria:

- `just test` on macOS and iOS still passes on a machine signed into iCloud.
- No `iCloud.rocks.moolah.app.v2` entitlement on the binary used by `xcodebuild test` (verified with `codesign -d --entitlements :-`).
- `[BackgroundSync] CloudKit available — starting sync coordinator` never logs during `just test`.
- CI stays green (no new signing / provisioning requirements).

## Non-goals

- Restructuring app sources into a framework for host-less testing.
- Changing `fastlane` distribution flow.
- Removing runtime defence (the `NSClassFromString("XCTestCase")` gate and `cloudKitDatabase: .none` stay).

## Approach

A dedicated `Debug-Tests` build configuration, selected by the test action of every scheme, that cannot receive iCloud entitlements regardless of what else happens to the Debug config.

The scheme's test action is what `xcodebuild test -scheme …` runs, so `just test`, `just test-ios`, `just test-mac`, and `just benchmark` all pick up the new config automatically. The run action stays on Debug, so local `just run-mac` keeps iCloud.

### Why not options B or C

- **Separate `Moolah_*_TestHost` app targets (B)** — strongest isolation but doubles target surface. Every future change to `Moolah_iOS` / `Moolah_macOS` (new framework dep, new source directory, new Info.plist key) has to be mirrored. Option A gets the same default-safety from one new config.
- **Host-less test target (C)** — requires extracting app sources into a framework. Breaks `@main` assumptions and anything reading `Bundle.main`. Worth considering for a broader test-architecture refactor, but not for this issue.

## Changes

### 1. Declare the configurations (`project.yml`)

Add a top-level `configs:` block (currently missing — xcodegen uses its defaults of Debug/Release):

```yaml
configs:
  Debug: debug
  Debug-Tests: debug
  Release: release
```

`Debug-Tests` inherits all Debug behaviour (optimisation off, debug symbols, assertions on) but is a distinct named config that per-target overrides and per-scheme selection can target.

### 2. Per-target overrides (`project.yml`)

For both `Moolah_iOS` and `Moolah_macOS`, add a `Debug-Tests` override that explicitly clears iCloud:

```yaml
    configs:
      Debug-Tests:
        CODE_SIGN_ENTITLEMENTS: ""
        SWIFT_ACTIVE_COMPILATION_CONDITIONS: "$(inherited)"
      Release:
        # existing Release block stays unchanged
```

`CODE_SIGN_ENTITLEMENTS: ""` overrides any entitlements file set at target scope by the inject script — so even if `Debug` later gets iCloud pinned into `project.yml` directly, `Debug-Tests` still signs with no entitlements file. The `SWIFT_ACTIVE_COMPILATION_CONDITIONS: "$(inherited)"` line ensures `CLOUDKIT_ENABLED` does not leak in through base settings; `$(inherited)` here deliberately drops any condition that only exists at base scope and is not otherwise re-added.

No changes needed on `MoolahTests_iOS`, `MoolahTests_macOS`, `MoolahBenchmarks_macOS` — they already have `CODE_SIGNING_REQUIRED: NO` / ad-hoc signing, and inherit host config from the scheme.

### 3. Point each test scheme at `Debug-Tests` (`project.yml`)

Update the `test:` action of every scheme:

```yaml
schemes:
  Moolah-iOS:
    build:
      targets:
        Moolah_iOS: all
    test:
      config: Debug-Tests
      targets:
        - MoolahTests_iOS

  Moolah-macOS:
    build:
      targets:
        Moolah_macOS: all
    test:
      config: Debug-Tests
      targets:
        - MoolahTests_macOS

  Moolah-Benchmarks:
    build:
      targets:
        Moolah_macOS: all
        MoolahBenchmarks_macOS: [test]
    test:
      config: Debug-Tests
      targets:
        - MoolahBenchmarks_macOS
```

The default `Moolah` scheme (run-only, no test action) stays on Debug — it's what `just run-mac` uses.

### 4. Scope injected entitlements to `Debug` (`scripts/inject-entitlements.sh`)

Rewrite the script so that when `ENABLE_ENTITLEMENTS=1`:

- The entitlements block is nested under `configs.Debug:` on each app target (not at target scope).
- `CLOUDKIT_ENABLED` is added under `settings.configs.Debug:` (not `settings.base:`).

After the change, with `ENABLE_ENTITLEMENTS=1`:

| Config       | Entitlements file                    | `CLOUDKIT_ENABLED` |
|--------------|--------------------------------------|--------------------|
| Debug        | `.build/Moolah.entitlements` (full)  | Yes                |
| Debug-Tests  | none (explicitly empty)              | No                 |
| Release      | (fastlane xcargs)                    | Yes (committed)    |

With `ENABLE_ENTITLEMENTS=0` (CI default), no injection happens; Debug-Tests still resolves to "no entitlements" and carries no `CLOUDKIT_ENABLED`.

### 5. Post-build verification (`scripts/test.sh`)

After the `xcodebuild test` run completes on each platform, assert the test host binary was not signed with any iCloud entitlement. This catches regressions in the config wiring even when no test explicitly triggers sync.

A new script `scripts/assert-no-icloud-in-test-host.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
HOST="$1"
if codesign -d --entitlements :- "$HOST" 2>&1 | grep -qi 'icloud'; then
  echo "ERROR: test host $HOST is signed with iCloud entitlements" >&2
  codesign -d --entitlements :- "$HOST" >&2 || true
  exit 1
fi
```

`scripts/test.sh` calls it at the end of `run_mac` / `run_ios` with the appropriate derived-data path. On macOS the target is `…/Debug-Tests/Moolah.app/Contents/MacOS/Moolah`; on iOS Simulator it is `…/Debug-Tests-iphonesimulator/Moolah.app`.

The check is cheap (one `codesign` spawn per platform) and runs on every `just test`. If it fires, the test run exits non-zero and CI fails.

### 6. Runtime defence stays in place

Per the decision made during brainstorming, the `NSClassFromString("XCTestCase")` gate in `App/MoolahApp.swift` and the `cloudKitDatabase: .none` setting in `MoolahTests/Support/TestModelContainer.swift` remain as belt-and-braces. They protect against any future path that reintroduces iCloud access to the test host (e.g. someone explicitly running the test scheme with `-configuration Debug`).

## Verification plan

Manual checks before landing:

1. `ENABLE_ENTITLEMENTS=1 just test` on macOS signed into iCloud — passes.
2. `codesign -d --entitlements :- .DerivedData-mac/Build/Products/Debug-Tests/Moolah.app/Contents/MacOS/Moolah` — no `iCloud.*` keys.
3. `ENABLE_ENTITLEMENTS=1 just run-mac` — app launches with iCloud working (sync coordinator starts, profiles load).
4. `codesign -d --entitlements :- .build/Build/Products/Debug/Moolah.app/Contents/MacOS/Moolah` — includes `com.apple.developer.icloud-container-identifiers`.
5. `just test` with `ENABLE_ENTITLEMENTS=0` — passes on both platforms.
6. `just benchmark` — still runs.
7. `just generate` in both modes — produces a valid project.
8. `ENABLE_ENTITLEMENTS=1 just test` filtering log output for `CloudKit available — starting sync coordinator` — zero occurrences.

Automated: `scripts/assert-no-icloud-in-test-host.sh` runs every test invocation, including CI.

## Risks and trade-offs

- **Extra config dimension.** Devs opening the project in Xcode will see `Debug-Tests` in the configuration dropdown. Benign; `Debug` stays the default for Run. Documented in `justfile` comments for discoverability.
- **xcodegen scheme regeneration.** The test config must be written into the generated `.xcscheme` XML. xcodegen supports `test.config:` — verify during implementation (fall back to `test.configuration:` key if the former doesn't apply).
- **Inject-script regex fragility.** `scripts/inject-entitlements.sh` currently pattern-matches target headers with a regex. Scoping under `configs.Debug:` means it has to find or create that nested block on each target. The rewrite is small but the script becomes slightly more coupled to `project.yml` layout. Mitigation: add a sanity assertion at the end that both `Debug` entitlements blocks exist in the generated file, and bail if not.
- **Partial fastlane coverage.** This design does nothing for `fastlane` because fastlane uses `-configuration Release` and does not run tests. If that ever changes (e.g. UI tests on TestFlight), the new scheme-based wiring must be revisited.

## Out of scope

- Removing the `ENABLE_ENTITLEMENTS=1` flow in favour of committing entitlements directly to `project.yml`. Would require provisioning-profile changes on CI and is a separate conversation.
- Converting test targets to host-less bundles (Option C).
- Replacing runtime XCTest gate with environment-variable gate (orthogonal; a later cleanup if desired).

## Acceptance criteria checklist

- [ ] `just test` (iOS + macOS) passes on a machine signed into iCloud with `ENABLE_ENTITLEMENTS=1`.
- [ ] `just test` passes on CI with `ENABLE_ENTITLEMENTS=0`.
- [ ] `codesign -d --entitlements :-` on the Debug-Tests host shows no `iCloud.*` keys.
- [ ] `[BackgroundSync] CloudKit available — starting sync coordinator` never logs during `just test`.
- [ ] `just run-mac` with `ENABLE_ENTITLEMENTS=1` still starts the sync coordinator and reaches iCloud.
- [ ] `scripts/assert-no-icloud-in-test-host.sh` invoked by `scripts/test.sh` on both platforms.
- [ ] Runtime XCTest gate in `MoolahApp.init()` and `cloudKitDatabase: .none` in `TestModelContainer` preserved.
