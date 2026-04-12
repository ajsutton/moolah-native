# Known Bugs

## iOS Simulator Tests Crash on Launch

**Severity:** Test infrastructure
**File:** App/ProfileSession.swift:57

The iOS simulator test target (`MoolahTests_iOS`) crashes on launch with
`SwiftDataError(.loadIssueModelContainer)`. The `try!` in `ProfileSession` fails because the
CloudKit-backed `ModelContainer` requires an iCloud account (`CKAccountStatusNoAccount`), which the
simulator doesn't have.

The macOS test target works fine because tests use in-memory SwiftData containers via `TestBackend`, but
the iOS target launches the full app which hits the production `ProfileSession` init path.

**Fix options:**
- Guard the CloudKit container setup with an iCloud account availability check
- Use an in-memory fallback container when no iCloud account is available
- Separate the test host so it doesn't run through `ProfileSession`
