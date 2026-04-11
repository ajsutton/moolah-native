# App Store Readiness Plan

Status: **Not Ready**
Date: 2026-04-11

This document lists everything required to pass Apple App Store Review for Moolah. Items are prioritized by severity.

---

## Blockers — Must Fix

### 1. Add Privacy Policy

**Guideline:** 5.1.1(i)
**Status:** Missing entirely

A privacy policy is required for all apps, and finance apps are held to a higher standard.

**TODO:**
- [ ] Write a privacy policy covering: what financial data is collected, how it's stored (iCloud/CloudKit, Keychain), retention and deletion policies, and that no data is shared with third parties (no analytics/tracking SDKs are used)
- [ ] Host the privacy policy at a public URL (e.g., `moolah.rocks/privacy`)
- [ ] Add a "Privacy Policy" link in the Settings screen within the app
- [ ] Add the privacy policy URL in App Store Connect metadata

> **If remote backend is disabled:** Still required, but the policy is simpler — data only lives on-device and in the user's own iCloud account. No third-party server data handling to disclose.

---

### 2. Add Contact / Support Information

**Guideline:** 1.5
**Status:** Missing entirely

Apps must include easily discoverable contact information.

**TODO:**
- [ ] Add a support email address or support URL
- [ ] Add an "About" or "Support" section in Settings with this information
- [ ] Provide a Support URL in App Store Connect metadata

---

### 3. Add Sign in with Apple

**Guideline:** 4.8
**Status:** Not implemented

Google OAuth is offered as a third-party login. Any app using third-party login must also offer Sign in with Apple.

**TODO:**
- [ ] Implement Sign in with Apple using `AuthenticationServices`
- [ ] Offer it alongside Google OAuth on the sign-in screen
- [ ] Handle token exchange with the remote backend

> **If remote backend is disabled:** Not required. CloudKit uses implicit Apple ID auth — no third-party login is presented, so Sign in with Apple is not needed.

---

### 4. Add In-App Account Deletion

**Guideline:** 5.1.1(v)
**Status:** Partial — CloudKit profiles have cascade delete via `ProfileDataDeleter`, but remote profiles only "Remove" from the app without deleting server-side data

If users can create accounts, they must be able to delete their account and all associated data from within the app.

**TODO:**
- [ ] For remote/Moolah profiles: implement a server-side account deletion API endpoint and wire it to a "Delete Account" button in Settings
- [ ] Ensure the UI clearly distinguishes "Remove from this device" vs "Delete all data permanently"
- [ ] CloudKit profiles already support full deletion — verify the UI flow is clear and discoverable

> **If remote backend is disabled:** Already handled. CloudKit profiles have `ProfileDataDeleter` with cascade delete, and the Settings UI has a destructive "Delete" button with a warning confirmation.

---

## Advisory — Strongly Recommended

### 5. Prepare Demo Access for App Review

**Guideline:** 2.1
**Status:** Not prepared

App Review must be able to use all features. If there's a login wall, you must provide credentials or a demo mode.

**TODO:**
- [ ] Create a demo account pre-loaded with sample financial data
- [ ] Document credentials and instructions in App Review notes
- [ ] Ensure the backend is live and stable during the review window

> **If remote backend is disabled:** Much simpler. No login wall — reviewers can launch and use the app immediately. Consider pre-seeding sample data on first launch (or providing instructions to add data manually).

---

### 6. Verify iPad Layout

**Guideline:** 2.4.1
**Status:** Relies on SwiftUI adaptive defaults — no explicit iPad layout code

iPhone apps should provide a good experience on iPad.

**TODO:**
- [ ] Test the app on iPad simulator (multiple sizes)
- [ ] Verify `NavigationSplitView` works correctly on iPad (not just scaled-up iPhone)
- [ ] Check that forms, lists, and charts use available screen space well
- [ ] Fix any layout issues found

---

### 7. Test IPv6 Compatibility

**Guideline:** 2.5.5
**Status:** Untested

Apps must work on IPv6-only networks. This is a common rejection reason.

**TODO:**
- [ ] Test using macOS "Create NAT64 Network" (System Settings > Sharing > Internet Sharing)
- [ ] Verify all network calls to `moolah.rocks` work over IPv6-only
- [ ] Ensure no hardcoded IPv4 addresses in networking code

> **If remote backend is disabled:** Not a concern. CloudKit networking is handled by Apple and is guaranteed IPv6 compatible.

---

### 8. Consider Legal Entity Developer Account

**Guideline:** 5.1.1(ix)
**Status:** Unknown — depends on developer account type

Apps in financial services "should be submitted by a legal entity, not an individual developer."

**TODO:**
- [ ] Evaluate whether to enroll as an organization in the Apple Developer Program
- [ ] If submitting as an individual, prepare App Review notes explaining Moolah is a personal budgeting organizer — it does not hold funds, execute transactions, or provide financial services

> **If remote backend is disabled:** Much lower risk. With data stored only in the user's own iCloud, the app is clearly a personal organizer rather than a financial service.

---

## Already Compliant

These areas were reviewed and require no action:

| Area | Status | Notes |
|------|--------|-------|
| Data Security (1.6) | Pass | HTTPS, Keychain storage, no third-party SDKs |
| In-App Purchases (3.1) | Pass | No premium features or IAP needed |
| Content Safety (1.1) | Pass | No objectionable content |
| Permissions (5.1.1(iii)) | Pass | No device permissions requested (no camera, location, contacts) |
| Minimum Functionality (4.2) | Pass | Genuine native utility with offline support |
| Third-Party SDKs | Pass | None used — only Apple frameworks |
| No Tracking/Analytics | Pass | No analytics, advertising, or tracking SDKs |
| Push Notifications (4.5.4) | N/A | Not implemented |

---

## Summary: Remote Backend Impact

If the remote backend were disabled (iCloud-only), the following items would no longer be issues:

| Item | Why it goes away |
|------|-----------------|
| Sign in with Apple | No third-party login offered |
| Account Deletion | CloudKit cascade delete already works |
| Demo Account | No login wall for reviewers |
| IPv6 Compatibility | Apple handles CloudKit networking |
| Legal Entity Risk | Personal organizer, not a service |
| Privacy Policy Complexity | Much simpler — user's own iCloud only |

**Remaining work with iCloud-only:** Privacy policy (simpler version), contact/support info, iPad layout verification.
