# Profile Settings Dialog with URL Validation

## Context
Users need to manage profiles (add/edit/remove) before logging in. Currently, profiles can only be added during initial setup or via "Add Profile..." in the user menu (which requires being logged in). Custom server URLs are not validated, so users can add profiles pointing to invalid servers and hit confusing errors later.

## Design: Apple Mail-style Account Management

### macOS
- **Settings scene** (Cmd+, / App menu > Settings) with an "Accounts" section
- Left sidebar: list of profiles with +/- buttons at bottom (like Mail's account list)
- Right detail: edit profile fields (label, server URL, currency, financial year start)
- Settings window is always accessible, even before login — `ProfileStore` is injected directly into the `Settings` scene from `MoolahApp`

### iOS
- "Manage Profiles..." accessible from the user menu
- On first run (ProfileSetupView), a gear button in the toolbar opens settings

### First Run (ProfileSetupView)
- Modeled after Mail's initial "Add Account" experience
- Default option: "Sign in to Moolah" (validates `moolah.rocks` URL)
- Custom server option: enter URL + label, validates before adding
- Both paths validate the server URL before creating the profile

## Plan

### 1. ServerValidator protocol (Domain layer)
**New file:** `Domain/Repositories/ServerValidator.swift`
- `protocol ServerValidator: Sendable` with `func validate(url: URL) async throws`

### 2. RemoteServerValidator (Backends)
**New file:** `Backends/Remote/Validation/RemoteServerValidator.swift`
- Creates ephemeral `APIClient` with candidate URL, calls `GET auth/`
- Decodes `{"loggedIn": Bool}` — if response parses, server is valid
- Wraps all failures (network, non-JSON, missing field) into `BackendError.validationFailed(message)`

### 3. InMemoryServerValidator (test double)
**New file:** `Backends/InMemory/InMemoryServerValidator.swift`
- Configurable `shouldSucceed` flag for tests

### 4. ProfileStore gains validation
**Modify:** `Features/Profiles/ProfileStore.swift`
- Add optional `validator: (any ServerValidator)?` to init (nil = skip validation, backward compat for tests)
- Add `isValidating: Bool` and `validationError: String?` observable state
- Add `validateAndAddProfile(_ profile:) async -> Bool`
- Add `validateAndUpdateProfile(_ profile:) async -> Bool`
- Both validate URL first, only persist on success, set error on failure

### 5. SettingsView — macOS Settings scene root
**New file:** `Features/Settings/SettingsView.swift`
- Mail-style layout: `List` sidebar with profiles + detail pane
- Profile list with +/- buttons at bottom of the list (like Mail's Accounts pane)
- "+" opens add profile form inline or as sheet
- "-" removes selected profile (with confirmation if it's the active profile)
- Selecting a profile shows its editable details in the detail area

### 6. ProfileFormView — add/edit profile form
**New file:** `Features/Profiles/Views/ProfileFormView.swift`
- Accepts optional `Profile` (nil = add, non-nil = edit)
- Form with Server URL + Label fields
- Shows `profileStore.validationError` inline as red label with warning icon
- Shows ProgressView during validation
- Cancel/Add|Save toolbar buttons
- Used both from SettingsView (edit detail pane) and as a sheet (add new)

### 7. Add Settings scene to MoolahApp
**Modify:** `App/MoolahApp.swift`
- Add `Settings { SettingsView().environment(profileStore) }` scene (macOS only)
- Inject `RemoteServerValidator()` into `ProfileStore` init

### 8. Update ProfileSetupView
**Modify:** `Features/Profiles/Views/ProfileSetupView.swift`
- "Sign in to Moolah" and "Connect" buttons use `profileStore.validateAndAddProfile()` async
- Show ProgressView overlay during validation, disable buttons
- Show validation error inline below form fields
- Clear error when user edits the URL field
- Add toolbar gear button (iOS) that opens SettingsView as a sheet — visible only makes sense once profiles exist, but on first run the setup view is the entry point

### 9. Update UserMenuView
**Modify:** `Features/Auth/UserMenuView.swift`
- On iOS: add "Manage Profiles..." item → opens SettingsView as sheet
- On macOS: the Settings scene handles this (Cmd+,), but could also add a convenience menu item
- Keep existing profile switcher for quick switching

### 10. Delete AddProfileView
**Delete:** `Features/Profiles/Views/AddProfileView.swift`
- Fully replaced by ProfileFormView

## Testing (TDD order)

1. **ProfileStore validation tests** (append to `MoolahTests/Features/ProfileStoreTests.swift`):
   - `validateAndAddProfile` succeeds → profile added, no error
   - `validateAndAddProfile` fails → profile not added, error set
   - `validateAndUpdateProfile` succeeds/fails similarly
   - `isValidating` set during validation
   - nil validator → skips validation, adds directly

2. **RemoteServerValidator tests** (`MoolahTests/Backends/RemoteServerValidatorTests.swift`):
   - Using `URLProtocolStub` pattern (same as existing remote tests)
   - Valid `{"loggedIn": false}` → success
   - Valid `{"loggedIn": true, ...}` → success
   - Non-JSON response → validationFailed
   - Network error → validationFailed
   - HTTP 500 → validationFailed

## Key Files
- `App/MoolahApp.swift` — add Settings scene + inject validator
- `Features/Profiles/ProfileStore.swift` — add validation logic
- `Features/Settings/SettingsView.swift` — new Settings root (Mail-style)
- `Features/Profiles/Views/ProfileFormView.swift` — new unified add/edit form
- `Features/Profiles/Views/ProfileSetupView.swift` — add async validation
- `Features/Auth/UserMenuView.swift` — add Manage Profiles on iOS
- `Domain/Repositories/ServerValidator.swift` — new protocol
- `Backends/Remote/Validation/RemoteServerValidator.swift` — new implementation

## Verification
1. `just test` — all tests pass
2. `just build-mac` — no warnings
3. Manual: Cmd+, opens Settings with profile list (macOS)
4. Manual: fresh launch (no profiles) → enter bad URL → see error, enter good URL → profile created
5. Manual: Settings → select profile → edit label → save; delete profile
