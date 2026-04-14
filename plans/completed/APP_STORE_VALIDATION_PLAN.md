# App Store Validation Plan

**Goal:** Catch App Store / TestFlight validation errors locally and in CI, before attempting upload. Avoid the trial-and-error cycle of pushing tags and waiting for Apple's server-side validation.

**Current State:** Validation only happens server-side during `upload_to_testflight`. Errors like missing `UISupportedInterfaceOrientations` or `UILaunchScreen` are only discovered after a full build + upload attempt.

---

## Phase 1: Local Validation via `xcrun altool`

Add a justfile target that builds an archive and validates it without uploading:

```just
# Validate an iOS archive against App Store rules (requires signing)
validate-ios: generate
    bundle exec fastlane ios validate
```

Add a `validate` lane to the Fastfile that archives and runs `xcrun altool --validate-app` (or Fastlane's `deliver`/`pilot` with `skip_submission: true`). This catches server-side validation rules locally.

**Limitation:** Requires code signing (developer account), so only works on machines with credentials.

## Phase 2: CI Validation on Every Push

Add a validation step to `ci.yml` that catches common App Store rejection reasons without needing signing or Apple credentials:

### Info.plist Checks (no signing required)
- `UISupportedInterfaceOrientations` includes all four orientations
- `UILaunchScreen` or `UILaunchStoryboardName` is present
- `CFBundleShortVersionString` and `CFBundleVersion` use build setting variables
- `NSCameraUsageDescription` / `NSPhotoLibraryUsageDescription` present if those frameworks are linked
- No `UIRequiredDeviceCapabilities` that would accidentally exclude devices

### Bundle Structure Checks
- App icon asset catalog has all required sizes
- No embedded frameworks with mismatched minimum deployment targets

### Implementation
A shell script (`scripts/validate-appstore.sh`) that parses the generated Info.plist and checks for known requirements. Runs as part of `ci.yml` after `just generate`. No signing or Apple credentials needed.

## Phase 3: App Store Review Agent

Create a `.claude/agents/appstore-review.md` agent that:

- Reads `App/Info.plist` and `project.yml`
- Checks against known App Store Review Guidelines (privacy keys, orientation, launch screen, etc.)
- Verifies entitlements match App ID capabilities
- Flags potential review issues (e.g., missing privacy policy link, missing support URL)
- Can be invoked with `@appstore-review` before tagging a release

---

## Known App Store Validation Rules

Captured from our TestFlight submission attempts and Apple documentation:

| Rule | Key / Requirement | Status |
|------|-------------------|--------|
| iPad multitasking orientations | `UISupportedInterfaceOrientations` must include all 4 | Fixed |
| Launch screen | `UILaunchScreen` dict or `UILaunchStoryboardName` with actual storyboard | Fixed |
| Privacy usage descriptions | Required if linking Camera, Photos, Location, etc. frameworks | N/A currently |
| App icon | All required sizes in asset catalog | Untested |
| Minimum OS version | Must match deployment target | OK (set via build settings) |
| Bundle identifier | Must match App ID in developer portal | OK |
| CloudKit entitlements | Must match container in developer portal | OK |

This table should be updated as we encounter new validation failures.
