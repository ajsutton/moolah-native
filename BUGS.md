# Known Bugs

## Profile remove button click target too small

**Severity:** Low (UX)
**Files:** Profile list / settings view

The minus (-) button to remove profiles has a very small click target. It may not be using the full row height for its tap area.

## Windows flash "profile removed" on app launch

When the app first loads, all existing windows briefly show a "profile removed" message before updating to show the actual profile data. This happens because the profile list hasn't loaded yet when the windows render, so they can't find their profile and assume it was removed. Don't show the window content until profiles are loaded. Once profiles are loaded, if a window's profile is genuinely gone, close the window rather than showing a "removed" message.

## Transaction convenience accessors assume single-leg semantics

`Transaction` has several convenience accessors that return properties from `legs.first`:
- `earmarkId` → `legs.first?.earmarkId`
- `categoryId` → `legs.first?.categoryId`
- `primaryAccountId` → `legs.first?.accountId`
- `primaryAmount` → `legs.first?.amount`
- `type` → `legs.first?.type`

These assume the first leg is "special", which breaks for multi-leg transactions where different legs could have different earmarks, categories, or types. Need to audit all call sites for hidden single-leg assumptions and decide on proper multi-leg semantics (e.g. should `earmarkId` return the earmark from any leg that has one?).
