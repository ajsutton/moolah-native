# Settings & Preferences — Updated Plan

**Status:** Ready to implement
**Priority:** Medium
**Last updated:** 2026-04-09

---

## Context

Multi-profile support landed — each profile already has its own `serverURL` and `UserDefaults` persistence via `ProfileStore`. The remaining settings fall into three categories: per-profile preferences, remembered UI state, and a bug fix.

---

## 1. Bug Fix: monthEnd Should Use Today's Day

**File:** `Features/Analysis/AnalysisStore.swift`

`monthEnd` is currently hardcoded to `25`. The web app uses the current day-of-month (i.e., `Calendar.current.component(.day, from: Date())`), meaning financial months always end on "today." This is not a user preference — it's a computed value.

**Change:** Replace `var monthEnd: Int = 25` with a computed property:
```swift
var monthEnd: Int { Calendar.current.component(.day, from: Date()) }
```

Remove any UI for setting this value.

---

## 2. Per-Profile Preferences

These differ between profiles (e.g., personal AUD vs. work USD server).

### Default Currency
- Currently hardcoded to AUD in `Currency.swift`
- Store on `Profile` as `var currency: Currency`
- Default to AUD for existing/new profiles
- Use throughout the app wherever `Currency.defaultCurrency` is referenced

### Financial Year Start Month
- Currently hardcoded to July (Australian FY)
- Store on `Profile` as `var financialYearStartMonth: Int` (1–12, default 7)
- Only matters for annual reporting boundaries

### Storage Approach
Add fields to the `Profile` struct. They persist automatically via `ProfileStore`'s existing `UserDefaults` JSON encoding. No new persistence infrastructure needed.

---

## 3. Remembered UI State (Last-Used Values)

These are not preferences — just "remember what I last picked."

### Analysis History & Forecast Periods
- `historyMonths` (default 12) and `forecastMonths` (default 1) in `AnalysisStore`
- Persist last-selected values in `@AppStorage` (global, not per-profile)
- Restore on launch so the user sees the same view they left

### Storage Approach
Use `@AppStorage("analysisHistoryMonths")` and `@AppStorage("analysisForecastMonths")` directly in `AnalysisStore` or `AnalysisView`. Minimal code change.

---

## 4. Show Hidden Accounts/Earmarks

This is a view toggle, not a preference.

### macOS
- Add **View > Show Hidden Accounts** menu item (toggle, `⌘H` or similar)
- Use SwiftUI `Commands` — same pattern as existing `NewTransactionCommands`
- State stored in a `@FocusedValue` or propagated via environment

### iOS
- Add a button/toggle in the sidebar, matching the web app's placement
- Could be a simple toggle row at the bottom of the accounts section

### Implementation
- `AccountStore` and `EarmarkStore` already have `isHidden` filtering
- Add a `showHidden: Bool` binding that controls whether the filter is applied
- Persist with `@AppStorage("showHiddenAccounts")` (global)

---

## Implementation Order

1. **monthEnd bug fix** — trivial one-liner, independent
2. **Analysis history/forecast persistence** — small `@AppStorage` change
3. **Show hidden accounts/earmarks** — UI work (View menu + sidebar button)
4. **Per-profile currency & FY start** — requires `Profile` model change + propagation

Items 1–2 can ship independently. Items 3–4 are larger but self-contained.
