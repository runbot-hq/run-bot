# Privacy & Data Storage

RunBot is a macOS status-bar app that monitors GitHub Actions on your own repositories. This document explains exactly what data the app stores, where, and how — verified directly from the source code.

---

## Authentication & Credentials

RunBot uses the **GitHub OAuth Authorization Code flow** to authenticate. You sign in once inside the app; no external CLI tool is required.

### How it works

1. Clicking **Sign In** calls `OAuthService.makeSignInURL()` to build the GitHub authorization URL, then opens it in your default browser via `NSWorkspace.shared.open(url)`.
2. After you click **Authorize**, GitHub redirects back to `runbot://oauth/callback` with a short-lived code.
3. RunBot exchanges the code for an access token via a server-side POST to `github.com/login/oauth/access_token`.
4. The token is stored **exclusively in the macOS Keychain** using `Security.framework` with `kSecUseDataProtectionKeychain: true` and `kSecAttrAccessibleAfterFirstUnlock` — the same modern Data Protection Keychain used by Safari and iCloud.
5. The token is never written to `UserDefaults`, files, logs, or any other location.

> **CSRF protection:** A random `state` nonce is generated per sign-in and verified on callback — mismatches are rejected before the token exchange begins (`OAuthService.handleCallback()`).

### Token storage details (from `Keychain.swift`)

| Key | Value |
|---|---|
| `kSecAttrService` | `run-bot` |
| `kSecAttrAccount` | `github-oauth-token` |
| `kSecAttrAccessible` | `kSecAttrAccessibleAfterFirstUnlock` |
| Storage | macOS Data Protection Keychain |

To remove the token at any time: **Settings → Sign Out**, or `security delete-generic-password -s run-bot` in Terminal.

---

## GitHub OAuth Scopes

RunBot requests the following scopes at sign-in (from `OAuthService.swift`):

| Scope | Why it is needed |
|---|---|
| `repo` | Read workflow runs, jobs, steps, and logs for private repositories. Also required to generate runner registration tokens at repo level. |
| `read:org` | Discover which organisations the authenticated user belongs to, and list org-level workflow runs. |
| `admin:org` | Required to list and manage self-hosted runners on organisations where the user is an **owner**. Without this, `/orgs/{org}/actions/runners` returns 403 for owner-level accounts. |
| `manage_runners:org` | Fine-grained runner-management scope (introduced 2023). Requested alongside `admin:org` for forward-compatibility as GitHub migrates runner APIs to require it on fine-grained tokens. |
| `workflow` | Required to **Re-run**, **Re-run failed**, and **Cancel** workflow runs via the API. Read-only tokens silently fail these write actions. |

### Why not a fine-grained PAT?

Fine-grained tokens do not yet support all Actions and runner management endpoints RunBot depends on. Classic OAuth is currently the only option that covers the full feature set.

### What RunBot does NOT do with your token

- ❌ Does not make any API calls to read, write, or access repository source code or file contents (even though the `repo` scope technically permits this)
- ❌ Does not open issues, create pull requests, or write to repositories on your behalf
- ❌ Does not transmit your token to any server other than `api.github.com` and `github.com` (for the OAuth exchange)
- ❌ Does not log your token in console output, crash reports, or analytics

---

## Preferences & Settings

All user preferences are stored in **`UserDefaults.standard`** — the standard macOS per-app preferences store at `~/Library/Preferences/`. No preference data leaves your device.

### Global settings

| Setting | Type | Notes |
|---|---|---|
| Polling interval | Integer (seconds) | Global default; can be overridden per scope |
| Notify on success | Boolean | Global default; can be overridden per scope |
| Notify on failure | Boolean | Global default; can be overridden per scope |
| Watched scopes | String array | List of `owner/repo` or `org` slugs |

### Per-scope settings (keyed as `scope.<scope>.<field>`)

From `ScopePreferencesStore.swift`:

| Field | Key suffix | Type |
|---|---|---|
| Human-readable alias | `alias` | String |
| Polling interval override | `pollingInterval` | Integer |
| Notify on success override | `notifyOnSuccess` | Boolean |
| Notify on failure override | `notifyOnFailure` | Boolean |
| Failure hook enabled | `failureHookEnabled` | Boolean |
| Failure hook shell command | `failureHookCommand` | String |
| Local repo path | `localRepoPath` | String |
| Failure hook branch filter | `failureHookBranch` | String |

All per-scope keys are removed when a scope is deleted (`ScopePreferencesStore.cleanUp(scope:)`).

You can inspect or delete these values at any time:

```bash
# List all RunBot defaults
defaults read dev.eonist.runbot

# Delete all RunBot defaults
defaults delete dev.eonist.runbot
```

---

## Failure Hooks

When a workflow run fails, RunBot can optionally fire a **user-defined shell command** in Terminal (`FailureHookRunner.swift`). The following tokens are substituted before the command runs:

| Token | Substituted with |
|---|---|
| `$FAILURE_LOG` | The workflow job log text fetched from GitHub |
| `$LOCAL_PATH` | The local filesystem path you configured for this scope |
| `$BRANCH` | The branch name of the failed run |
| `$RUN_LINK` | The GitHub URL of the failed run |

The command, path, and branch filter are stored in `UserDefaults` as described above. **RunBot does not transmit failure logs anywhere** — they are fetched from `api.github.com` and passed directly to your local shell command.

---

## Network Activity

RunBot makes HTTPS requests **only** to:

- `api.github.com` — GitHub REST API (runs, jobs, steps, logs, runners)
- `github.com` — OAuth token exchange only (at sign-in)
- `*.amazonaws.com` — GitHub's job log endpoints (`/actions/jobs/{id}/logs`) return a 302 redirect to a pre-signed S3 URL. RunBot's `Authorization` token is **not** forwarded to S3; Apple's URLSession automatically strips the `Authorization` header before following cross-origin redirects (per RFC 7235). S3 authenticates purely via the pre-signed query parameters embedded in the redirect URL.

No analytics, telemetry, crash reporting, or third-party network calls are made. All API requests are made over TLS with your OAuth token in the `Authorization` header.

---

## In-Memory Data

All fetched run, job, step, and log data is held **in memory only**. Nothing is cached to disk between sessions. When you quit the app, all fetched data is discarded.

---

## macOS Permissions

| Permission | Why |
|---|---|
| **Notifications** | Optional — notifies on job success or failure when enabled in Settings |
| **Outbound network** | Required — to call `api.github.com` |
| **Launch at login** | Optional — registers a LoginItem via `ServiceManagement` when enabled |

RunBot does not request access to contacts, location, camera, microphone, Photos, or any other sensitive macOS permission category.

---

## GitHub OAuth Permissions

RunBot requests five OAuth scopes when you sign in with GitHub: `repo`, `read:org`, `admin:org`, `manage_runners:org`, and `workflow`. Here is exactly why each is needed.

**`repo`** — Required for three core features: fetching step and run logs (`GET .../jobs/{job_id}/logs`, `GET .../runs/{run_id}/logs`), generating runner registration tokens (`POST .../runners/registration-token`), and polling workflow run and job status (`GET .../actions/runs`, `GET .../runs/{run_id}/jobs`). Without it the GitHub API returns 403 for all of these.

**`read:org`** — Grants read-only access to org membership and org-level Actions data for users who are **org members but not owners**: `GET /orgs/{org}/actions/runners`, `GET /orgs/{org}/actions/runs`, and `GET /user/orgs` (scope picker). Without it, only `owner/repo`-scoped monitoring works.

**`admin:org`** — Required to call the runners API on organisations where the authenticated user is an **owner**. For org owners, `read:org` alone is insufficient — `GET /orgs/{org}/actions/runners` returns 403 without `admin:org`. This is a GitHub API requirement, not a RunBot design choice.

**`manage_runners:org`** — A fine-grained runner management scope introduced by GitHub in 2023, requested alongside `admin:org` for forward-compatibility. GitHub is progressively migrating runner management APIs to require this explicit scope; requesting it now avoids forcing users to re-authenticate later.

**`workflow`** — Required for write actions on workflow runs: re-run (`POST .../rerun`), re-run failed jobs (`POST .../rerun-failed-jobs`), and cancel (`POST .../cancel`). Without it, these fail silently with 403 even when `repo` is present.

### What RunBot does NOT do

- Does not read, write, or access repository source code or file contents (even though `repo` technically permits this)
- Does not write to repositories, open issues, or create pull requests on your behalf
- Does not access private user data beyond organisation membership
- Does not store your token anywhere other than the macOS Keychain on your local machine
- Does not transmit your token to any server other than `api.github.com` and `github.com`

---

## Open Source

RunBot is open source. You can audit every network call, every persistence write, and every credential access in the source code:

- OAuth flow: [`Sources/RunBotCore/GitHub/OAuthService.swift`](../../Sources/RunBotCore/GitHub/OAuthService.swift)
- Token storage: [`Sources/RunBotCore/GitHub/Keychain.swift`](../../Sources/RunBotCore/GitHub/Keychain.swift)
- GitHub API calls: [`Sources/RunBot/GitHub/GitHubURLSessionTransport.swift`](../../Sources/RunBot/GitHub/GitHubURLSessionTransport.swift)
- Per-scope preferences: [`Sources/RunBotCore/Scope/ScopePreferencesStore.swift`](../../Sources/RunBotCore/Scope/ScopePreferencesStore.swift)
- Failure hooks: [`Sources/RunBot/Services/FailureHookRunner.swift`](../../Sources/RunBot/Services/FailureHookRunner.swift)
