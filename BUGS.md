# Known Bugs

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

## iOS login page should allow changing profile without logging in

On iOS, the login page shows the currently selected remote profile but doesn't offer a way to switch to a different profile. The user should be able to change to another profile from the profile selector without having to log into the one that happens to be selected.

## macOS sidebar: account balance lacks contrast against selection highlight

During recent UI review fixes, the fix ensuring sufficient contrast between the account balance text and the sidebar selection colour on macOS was lost. The balance text becomes hard to read when its row is selected.

## Upcoming transactions analysis panel flashes on pay

When paying a transaction, the upcoming transactions analysis panel flashes its content as if doing a full reload. It should update incrementally without a visible flash.

## iCloud profile: transfers show incorrect balance in transaction list

In an iCloud profile, transfers cause the balance shown in the transaction list to be wildly inaccurate — transactions into an account are displayed as negative amounts. The sidebar shows the correct balance; only the transaction list running balance is wrong.
