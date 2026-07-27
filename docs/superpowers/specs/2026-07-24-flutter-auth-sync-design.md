# Flutter Authentication and Sync Design

## 1. Purpose

This document defines the first Windows milestone for school authentication,
encrypted credential persistence, automatic and manual source sync, the local
Python bridge, operation history, settings, and failure handling.

It extends the confirmed application-shell and weekly-schedule design in
`2026-07-23-flutter-app-shell-schedule-design.md`. It does not add a real LLM,
daily briefing, Agent tools, cloud sync, or mobile collection.

## 2. Scope

The first milestone supports:

- a dedicated persistent Edge profile for school sessions;
- mandatory protected storage of the verified school username and opt-in
  protected storage of the password;
- automatic sync when a source has not succeeded for 12 hours;
- manual sync of all or one source at any time;
- file import through the same Flutter import service;
- JW course and exam collection;
- registered second-classroom schedule collection;
- per-source freshness, progress, and failure state;
- an authenticated loopback bridge to existing Python source services;
- redacted sync and action history;
- account, storage, cache, and source settings.

Second-classroom registration and cancellation remain manual actions on the
official school page.

## 3. Authentication Model

Authentication is session-first and credential-assisted:

1. Reuse the dedicated Edge profile while its CAS session remains valid.
2. A non-interactive sync may test and use the existing session without
   showing a visible browser window.
3. If the source requires login, CAPTCHA, or other interaction, stop and
   return `needs_user_action`.
4. Show an in-App prompt. Do not open a visible Edge window automatically.
5. Open visible Edge only after the user chooses to continue.
6. If the user opted to save credentials, fill them only on an allowlisted
   official USTC login origin.
7. The user completes CAPTCHA and any other interactive verification.
8. Resume collection after the authenticated school page is reached.

If a source cannot be collected invisibly even with a valid session, automatic
sync transitions to `needs_user_action` instead of silently launching visible
UI.

Every sync may decrypt the protected school username briefly in memory for
local session/account verification. Password decryption remains forbidden until
the bridge reports `needs_user_action` and the user chooses to continue.
Neither plaintext value enters logs or SourceBundle.

First login uses an in-memory provisional random `accountId`. The App persists
the account and imports its bundle only after the school identity is verified;
failure or cancellation discards the provisional identity without creating an
account partition.

The App never recognizes, bypasses, or submits a CAPTCHA automatically.

## 4. Encrypted Credential Storage

### 4.1 Storage Decision

The verified school username is always stored as a protected blob in SQLite.
The password blob is nullable and stored only when the user opts in. The
ability to decrypt either value is bound to the current platform user and
device.

The encryption key or equivalent unwrapping capability must not be stored in
SQLite, source code, configuration, logs, exported data, or the Python bridge.

The Flutter application exposes a platform credential protector:

```text
protect(secret) -> versioned protected blob
unprotect(protected blob) -> short-lived secret
delete(account)
```

Platform behavior is:

- Windows: use current-user DPAPI protection. Do not use
  `CRYPTPROTECT_LOCAL_MACHINE`.
- Android: use an app-specific, non-exportable Android Keystore key for a
  standard authenticated-encryption scheme.
- iOS: use Keychain-protected key material or direct Keychain secret storage
  behind the same application interface.

Windows DPAPI is selected instead of Credential Locker for the first milestone
so credentials are not intentionally configured to roam with a Microsoft
account. DPAPI loss after an administrator resets a Windows account password
is handled as credential loss: the user enters the school password again.

### 4.2 SQLite Record

The credential table stores only protected material and non-secret metadata:

```text
credential_accounts
  id
  system
  display_hint
  protected_username
  protected_password
  protection_scheme
  protection_version
  protection_metadata
  saved_at
  updated_at
```

`protection_metadata` may contain a nonce or platform descriptor when required,
but never a decryption key.

Credentials are not included in App backup, export, sync, diagnostics, or
operation-history payloads.

### 4.3 Save and Use Rules

- Protected username storage is mandatory after school identity verification;
  only password storage is opt-in.
- Persist the protected username, and an opted-in protected password, only
  after a successful school login verifies the expected identity.
- Encryption failure aborts saving; plaintext fallback is forbidden.
- The username may be decrypted briefly for each local session/account
  verification.
- Decrypt the password only after the bridge requests interactive login and
  the user chooses to continue.
- Keep plaintext lifetime as short as the Dart, native, and Python runtimes
  reasonably allow.
- Never interpolate credentials into commands, URLs, status messages, or
  exceptions.
- Discard plaintext references immediately after form filling.
- Allow the user to update or delete saved credentials.
- Deleting protected credentials and clearing the Edge profile are separate
  actions.

This protects credentials when the SQLite file is copied independently. It
does not claim to protect against malware already controlling the current
user's unlocked session.

## 5. Sync Scheduling

### 5.1 Source Freshness

Freshness is calculated separately for JW and registered second-classroom
schedules:

```text
now - lastSuccessfulAt < 12 hours  -> fresh
now - lastSuccessfulAt >= 12 hours -> due
no successful sync                 -> due
```

The initial Windows release configures JW automatic and manual sync for:

```text
semesterId  = 421
semesterKey = 2026spring
displayName = 2026 春季学期
```

The App must not derive `semesterId` from a year or semester label. The mapping
is stored as source configuration so a later release can update or extend it
without changing imported event identities. Historical semesters already in
SQLite remain available and are not refreshed or deleted merely because the
configured automatic-sync semester changes.

Opening the App always renders SQLite data first. Freshness checks and
automatic work happen after the local UI is available.

### 5.2 Automatic Sync

For each due enabled source:

1. Start the temporary bridge if no bridge is running.
2. Attempt non-interactive collection with the persistent profile.
3. Import a complete returned bundle in one Flutter database transaction.
4. Update only that source's success and freshness state.
5. If login is required, set `needs_user_action` and show an in-App prompt.
6. If collection fails, retain old data and show its last successful time.

An automatic failure starts a one-hour automatic retry backoff for that source.
Manual sync bypasses both the 12-hour freshness interval and the backoff.

The App must not start a second sync while another school collection task owns
the browser profile.

### 5.3 Manual Sync and File Import

The drawer offers:

```text
Sync all
Sync JW
Sync registered second-classroom schedules
Import from file
```

`Sync all` executes enabled sources sequentially. One source can succeed while
another fails, but the UI must not label that outcome as complete success.

Manual and automatic collection return versioned source bundles. File import
accepts the same contract. All three paths call the same Flutter
`ImportService`.

File import requires explicit confirmation of a target account before
`ImportService` runs. The active account may be preselected, but it is not
silently accepted; the Bundle subject must match the confirmed target.

The normative v1 contract is `docs/data-sources/source-bundle-v1.md`, with
`schemas/source-bundle-1.0.schema.json` and shared fixtures under
the distinct `tests/fixtures/source-bundle/positive/` and
`tests/fixtures/source-bundle/negative/` directories. It applies only to JW
and registered second-classroom schedule snapshots. Active-enrolment, iCourse,
and campus query/detail results do not pass through ImportService.

A file bundle affects freshness only when its supported schema, local account
subject, source scope, completeness declaration, manifest, collection
timestamp, and semantic references pass validation. Older consumers reject a
newer unsupported minor version rather than guessing unknown fields.

## 6. Bridge Protocol and Lifecycle

### 6.1 Process Boundary

Flutter starts the Python bridge only when collection is required. The bridge:

- imports existing Python source services directly;
- does not run a collector CLI and parse terminal text;
- binds only to `127.0.0.1` on an operating-system-selected port;
- generates a random per-process authentication token;
- returns the port, protocol version, and token through the parent-child
  structured handshake;
- never places the token or school credentials in command-line arguments;
- accepts only authenticated requests from the App.

The first protocol can use loopback HTTP with structured JSON and a progress
stream. The fixed API surface contains only:

```text
health
collect_jw
collect_young_schedule
resume_interactive_login
cancel
shutdown
```

Requests use typed, bounded fields. The bridge rejects arbitrary shell
commands, URLs, filesystem paths, source names, and unsupported parameters.

### 6.2 Progress and Results

Bridge progress messages contain stable phases and safe counts, not remote
request details:

```text
starting
checking_session
needs_user_login
waiting_for_user
collecting
normalizing
complete
cancelled
failed
```

The bridge returns a source bundle only after the source service has produced a
complete normalized result. It never presents a partial bundle as complete.
One Bundle represents exactly one logical source and one database transaction;
JW contains both course-table and exam components, while registered
second-classroom schedules use an independent date-window Bundle.

Raw responses, cookies, tokens, CAS tickets, browser-profile paths, and JW
context identifiers do not cross into Flutter.

### 6.3 Shutdown

- School collection tasks run sequentially.
- App cancellation closes the active browser context and discards incomplete
  output.
- App exit terminates the child bridge.
- The bridge watches its parent where supported and also has an idle timeout.
- A bridge crash leaves the last committed SQLite state unchanged.
- The next App launch can recover from an abandoned `running` sync record by
  marking it interrupted.

## 7. Source and Sync State

Each source has one current state:

```text
idle
due
running
needs_user_action
succeeded
failed
cancelled
```

The App displays:

- current source state;
- last attempt time;
- last successful time;
- whether local data is stale;
- progress phase while running;
- a redacted user-facing error when failed;
- a continue-login action when user input is required.

`needs_user_action` is a normal authentication state, not a system failure.

## 8. Accounts, History, and Settings

### 8.1 School Accounts

The school-account screen shows:

- JW and second-classroom connection state;
- last successful authentication time;
- a masked saved-account hint;
- whether a password is saved;
- update saved login;
- delete saved credentials;
- log in again;
- open an official school page;
- clear the dedicated browser session.

Deleting credentials and clearing the browser profile require separate
confirmations.

During first login, the provisional random `accountId` remains in memory and is
not displayed as a persisted account. Verified success persists that account
and its first complete Bundle; failure or cancellation discards it.

### 8.2 Operation History

Add an `action_logs` table. It records:

- automatic, manual, and file sync;
- attendance, listening, and note changes;
- overlap foreground-priority changes;
- credential saved, updated, or deleted;
- browser session cleared;
- database migrations;
- important setting changes.

Logs contain action type, safe summary, actor, target reference, timestamp,
result, and necessary redacted before/after state. They never contain
credentials, protected blobs, cookies, tokens, raw responses, or a complete
schedule payload.

History is read-only in the first milestone and can be filtered by time,
source, action type, and result.

### 8.3 First-Milestone Settings

Settings contain:

- automatic sync on or off;
- a fixed 12-hour automatic interval;
- JW and second-classroom source toggles;
- school-account and credential management;
- local storage location and usage;
- clear cache;
- clear local business data;
- clear all credentials and browser sessions.

Turning off a source stops refresh and does not delete history.

Clearing cache does not delete SQLite schedules or overlays. Clearing business
data does not implicitly delete credentials. A complete local-data reset lists
each affected category and requires a second confirmation.

Cloud sync, sharing, LLM API configuration, and Agent permission settings are
not part of this milestone. An unused `agent_permission_policies` schema shell
exists for the next milestone, but it has no settings UI, default grants, or
runtime effect.

## 9. Failure Handling

- App startup never waits for remote sync before showing local data.
- A failed source keeps its last committed records.
- Bundle validation failure rejects the entire bundle.
- A cancelled or interrupted task imports no partial output.
- Credential decryption failure asks the user to re-enter credentials.
- Encryption failure never falls back to plaintext.
- Automatic failures honor the one-hour backoff.
- Manual sync remains available immediately.
- Stable error codes separate authentication, source-contract, bridge,
  validation, database, cancellation, and credential-protection failures.
- User-visible and diagnostic errors remain redacted.

## 10. Automated Verification

Python tests cover:

- bridge protocol version and token enforcement;
- rejection of unsupported operations, URLs, and paths;
- parent exit, explicit cancel, and idle timeout;
- authentication-required classification;
- source-failure classification;
- complete-bundle-only result behavior;
- redaction of progress and errors.

Flutter tests cover:

- Drift schema and migrations;
- idempotent import;
- rolling-window history preservation;
- overlay preservation during refresh;
- per-source 12-hour due calculation;
- one-hour automatic failure backoff;
- manual bypass of freshness and backoff;
- independent per-source success;
- interrupted-run recovery;
- credential-protector failure without plaintext persistence;
- copied SQLite contains no plaintext username or password;
- Windows current-user DPAPI platform behavior remains covered;
- non-empty adversarial action-history data is sanitized in every visible
  field;
- account and destructive-setting confirmations.

Platform integration tests cover:

- Windows current-user DPAPI round trip;
- failure to decrypt under an unrelated context where practical;
- credential deletion;
- absence of plaintext credentials in copied SQLite and logs.

Existing source tests remain isolated from school websites. Real school-page
behavior is accepted manually with a dedicated Edge session.

## 11. Real Acceptance

The Windows milestone is accepted only after these scenarios pass:

1. Importing JW and second-classroom JSON creates the expected schedule.
2. Reimport is idempotent and preserves overlays.
3. Opening the App after 12 hours triggers an automatic attempt.
4. A valid session completes without user interaction.
5. An expired session produces only an in-App prompt.
6. Visible Edge opens only after the user chooses to continue.
7. Saved credentials fill only on the allowlisted official login page.
8. The user completes CAPTCHA manually and collection resumes.
9. JW success and second-classroom failure remain visibly independent.
10. Copying SQLite does not reveal username or password plaintext.
11. Deleting credentials does not clear the browser session, and clearing the
    browser session does not silently delete credentials.
12. Source and action history contains no authentication material.
13. First-login failure or cancellation leaves no persisted provisional
    account, while verified success persists the account and imports only its
    matching Bundle.
14. File import requires confirmation of its target account even when the
    active account is preselected.

## 12. Security References

- Microsoft DPAPI `CryptProtectData`:
  https://learn.microsoft.com/windows/win32/api/dpapi/nf-dpapi-cryptprotectdata
- Android Keystore:
  https://developer.android.com/privacy-and-security/keystore
- Apple Keychain Services:
  https://developer.apple.com/documentation/security/keychain-services
- OWASP Mobile App Cryptography:
  https://mas.owasp.org/MASTG/0x04g-Testing-Cryptography/
