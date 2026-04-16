# Earmark-Only Transaction Support

## Problem

Earmark-only transactions (legs with `earmarkId` set but `accountId` nil) exist in the server data model and are fully supported by the web UI, but the native app doesn't handle them properly. The native detail view shows all fields (Type, Payee, Account, Category) even though they're irrelevant for earmark-only transactions, and validation incorrectly requires every leg to have an `accountId`.

## Design

### Data Model & Business Logic (TransactionDraft)

All earmark-only logic lives in `TransactionDraft` and `LegDraft`, keeping views thin.

**LegDraft changes:**

- Add computed property `isEarmarkOnly: Bool` — returns `true` when `accountId == nil && earmarkId != nil`.
- When a leg becomes earmark-only (observed via `accountId` changing to nil while `earmarkId` is set), enforce invariants:
  - Force `type` to `.income`
  - Clear `categoryId` to nil
  - Clear `categoryText` to empty string

**TransactionDraft validation (`isValid`):**

- A leg is valid if it has `accountId != nil` OR `earmarkId != nil` (at least one).
- A leg with `accountId == nil && earmarkId == nil` is invalid.
- Simple transfer constraint: both legs must have accounts. A simple transfer cannot have an earmark-only leg.

**TransactionDraft initialization:**

- `init(accountId:viewingAccountId:)` gains an optional `earmarkId: UUID?` parameter. When provided with no accountId, creates an earmark-only draft.
- `init(from:viewingAccountId:)` unchanged — earmark-only legs from existing transactions flow through naturally.

### Simple Mode Form Adaptation

When `draft.relevantLeg.isEarmarkOnly`:

- **Hide:** Type section, Payee field, Account section, Category section
- **Show:** "Earmark funds" header, Earmark picker (no "None" option), Amount, Date, Notes
- The earmark picker is prominent — it identifies what this transaction is for

When the leg is not earmark-only, the form is unchanged (including the existing earmark picker in the category section for legs with both account and earmark).

### Custom Mode Sub-Transaction Adaptation

Each sub-transaction section independently adapts based on `legDrafts[index].isEarmarkOnly`:

- **Earmark-only leg:** Hide Type and Category rows. Show Earmark picker (no "None" option), Account picker (showing "None" selected, allowing user to assign an account to convert it), Amount.
- **Account-based leg:** All fields as today — Type, Account, Amount, Category, Earmark (optional).

### Transaction Creation

**From earmark view (earmark selected in sidebar):**
- Initialize draft with `accountId: nil, earmarkId: earmark.id` on the primary leg.
- The form automatically shows the simplified earmark-only view.
- Requires updating `EarmarkDetailView`'s transaction creation flow to pass the earmark ID through.

**From upcoming view:**
- No changes. Single add button creates a normal transaction. Users can convert to earmark-only by clearing the account and selecting an earmark.

### What Does NOT Change

- `TransactionType` enum — no new cases
- `TransactionLeg` domain model — already supports optional accountId and earmarkId
- `UpcomingView` — no new buttons or flows
- `Transaction.isSimple` — earmark-only single-leg transactions are already simple

### Testing

All business logic in `TransactionDraft` is tested via `TestBackend` (in-memory SwiftData). Tests cover:

- `LegDraft.isEarmarkOnly` for all combinations of accountId/earmarkId
- Invariant enforcement: setting accountId to nil with earmarkId set forces type to `.income`, clears category
- Validation: earmark-only legs are valid, legs with neither are invalid
- Simple transfer cannot have earmark-only legs
- Draft initialization with earmarkId parameter
- Round-trip: create earmark-only draft → build transaction → re-init draft from transaction
