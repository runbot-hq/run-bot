# Changelog

All notable changes to this project will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

---

## [Unreleased] — PR #75: EnvTokenKit / OAuthTokenKit extraction

### Breaking Changes

#### `OAuthServiceProtocol.isAuthenticated` — empty-string behaviour change

**Affected type:** `OAuthService` (in `OAuthTokenKit`)  
**Affected protocol:** `OAuthServiceProtocol.isAuthenticated`

**Before (pre-PR #75):**
```swift
public var isAuthenticated: Bool { tokenStore.load() != nil }
```
An empty string `""` stored in the Keychain returned `true`.

**After (PR #75):**
```swift
public var isAuthenticated: Bool { tokenStore.load().map { !$0.isEmpty } ?? false }
```
An empty string `""` now returns `false`.

**Why:** The old contract allowed a corrupted Keychain entry (`""`) to show the UI
as signed-in while every API call silently received no token. The new behaviour is
correct: an empty token is not a valid credential.

**Who is affected:**  
Any `MockOAuthService` (or other `OAuthServiceProtocol` conformer) that returns `""`
from `tokenStore.load()` to represent a signed-in state will silently flip to
`isAuthenticated == false` after upgrading.

**Migration:**  
Update mocks to return a non-empty string (e.g. `"test-token"`) to represent
a signed-in state. Returning `""` to represent signed-out is already correct and
requires no change.

See `OAuthServiceAuthStateTests.oauthService_isAuthenticated_emptyString` for the
covering test.

---

### Fixed

- **`OAuthService.handleCallback` — CSRF log message restored**  
  The diagnostic log string for a state-mismatch rejection was truncated to
  `"possible CSRF"` during extraction. Restored to the original:
  `"possible CSRF attempt, rejecting"`.  
  Ops/triage searching unified logs for `"CSRF attempt"` will now get matches again.
