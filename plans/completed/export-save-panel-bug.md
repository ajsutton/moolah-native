# Bug: NSSavePanel not displaying from SwiftUI Commands

## Status: Fixed

## Problem

The Export Profile menu item's NSSavePanel did not display when triggered from a SwiftUI `Commands` button. Both `runModal()` and `beginSheetModal(for:)` failed to show the panel.

## Root Cause

Two issues:

1. **Missing sandbox entitlement**: The app sandbox was enabled but `com.apple.security.files.user-selected.read-write` was not included in the entitlements. This entitlement is required for NSSavePanel/NSOpenPanel to function in a sandboxed app — without it, the powerbox service that presents the panel silently fails.

2. **Focused value not propagating to Commands**: `SessionRootView` used `.focusedValue()` which requires a specific view to have keyboard focus. Changed to `.focusedSceneValue()` so the session is available whenever the window/scene is active, regardless of which view has focus.

## Fix

- Added `com.apple.security.files.user-selected.read-write: true` to `scripts/inject-entitlements.sh`
- Changed `SessionRootView` from `.focusedValue()` to `.focusedSceneValue()` for both `authStore` and `activeProfileSession`
- Export uses `beginSheetModal(for:)` to present as a sheet attached to the profile window (proper macOS HIG pattern)
