# Settings/Preferences — Feature Idea

**Status:** Idea (not yet planned)
**Priority:** Medium — no settings page exists in the web app either, so this is enhancement-only
**Context:** The native app currently has zero persistence (`UserDefaults`/`@AppStorage` not used anywhere). All user state resets on launch.

---

## Motivation

Several values are hardcoded or ephemeral that should be user-configurable and persisted across launches.

---

## Candidate Settings

### Critical

**Server URL**
- Hardcoded to `http://localhost:8080/api/` in `MoolahApp.swift:69`
- Blocker for using the app outside of development
- Needs to be configurable before the app can connect to a real server

### High Value

**Financial month-end day**
- Defaults to 25 in `AnalysisStore.swift:18`, resets on launch
- Pay-cycle dependent, user-specific — shouldn't need to re-set every time

**Analysis history/forecast defaults**
- History defaults to 12 months, forecast to 1 month (`AnalysisStore.swift:16-17`)
- Not persisted — resets every launch
- Users who always want a different range have to reselect each session

**Show hidden accounts/earmarks toggle**
- Accounts and earmarks can be hidden (via EditAccountView), but there's no way to reveal them again
- `AccountStore` filters with `!$0.isHidden` (`AccountStore.swift:37-42`), `EarmarkStore` does the same (`EarmarkStore.swift:37-39`)
- Could live in settings or as a sidebar toggle — either way needs persistence

### Low Value

**Default currency**
- Hardcoded to AUD in `Currency.swift:4`
- Low urgency if single-user, but a one-line config change

**Financial year start month**
- Hardcoded to July 1 (Australian FY) in web app's `dates.js:4`
- Correct for Australia, wrong for US (Jan), UK (Apr), etc.
- Only matters if the app is ever used by non-Australian users

---

## Notes

- Building this would establish the `@AppStorage`/`UserDefaults` persistence pattern for the first time in the app
- macOS convention: Settings window via `⌘,` using SwiftUI `Settings` scene
- iOS convention: In-app settings screen (not Settings.app integration)
- The web app has no settings page at all
