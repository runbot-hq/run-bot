# GitHubClient

A lightweight, modern Swift GitHub API client for macOS apps. Direct REST calls over `URLSession`, zero external dependencies, Swift 6.2 strict concurrency throughout.

**Platform & Stack**

![macOS 26+](https://img.shields.io/badge/macOS-15%2B-black?logo=apple&logoColor=white)
![Swift 6.2](https://img.shields.io/badge/Swift-6.2-F05138?logo=swift&logoColor=white)
![SPM](https://img.shields.io/badge/SPM-compatible-F05138?logo=swift&logoColor=white)

**CI Checks & Review**

![Unit Tests](https://github.com/runbot-hq/GitHubClient/actions/workflows/swift-test.yml/badge.svg)
![SwiftLint](https://github.com/runbot-hq/GitHubClient/actions/workflows/swiftlint.yml/badge.svg)
![Periphery](https://github.com/runbot-hq/GitHubClient/actions/workflows/periphery.yml/badge.svg)
[![Greptile](https://img.shields.io/badge/🦎%20AI%20Review-Greptile-6C47FF?logoColor=white)](https://greptile.com)

## Contents

- [Features](#features)
- [Requirements](#requirements)
- [Package Targets](#package-targets)
- [Installation](#installation)
- [Usage](#usage)
- [Usage Examples](#usage-examples)
- [Authentication](#authentication)
- [License](#license)

## Features

- 🔐 **Dual authentication** — OAuth Authorization Code flow for interactive users; `GH_TOKEN` / `GITHUB_TOKEN` env var for CI and automation. Same call site, no branching
- 🪜 **Layered token resolution** — memory cache → Keychain → env var → login-shell fallback, resolved at call time
- 🌐 **Direct REST over `URLSession`** — no code generation, no auto-generated OpenAPI types, no third-party networking layer
- 🛡️ **Rate-limit aware** — automatic backoff and retry on 429 / 403 rate-limit responses
- 📄 **Link-header pagination** — cursor-based pagination handled transparently
- 🔑 **`KeychainTokenStore` built in** — ready-made Keychain integration via `Security.framework`; swap in a mock for tests via the `TokenStore` protocol
- ⚡ **Swift 6.2 strict concurrency** — no `@unchecked Sendable`, compiler-enforced boundaries throughout
- 🧪 **Testable by design** — every concrete type hidden behind a protocol; inject a fake transport or token store in tests with no Keychain involvement
- 🤖 **Self-hosted runner queries** — fetch all runners for an org or repo scope via `fetchRunners(scope:)` / `fetchRunners(scopeString:)`; returns `[GitHubRunner]` with name, status, busy flag, and labels. Pagination handled automatically
- ⚙️ **Workflow run & job inspection** — `fetchActiveRuns(scope:)` returns a typed `GitHubRunsFetchResult` distinguishing `.success`, `.rateLimited(partial)`, and `.noToken`; `fetchJobs(runID:scope:)` returns full `[GitHubJob]` trees with steps, runner name, and timestamps; `fetchStepLog(jobID:stepNumber:scope:)` fetches and parses raw CI logs per step, stripping ANSI codes automatically
- 👤 **User context helpers** — `fetchUserOrgs()` and `fetchUserRepos()` return the authenticated user's org login names and `owner/repo` full names; useful for building scope-picker UIs

## Requirements

- Swift 6.2+
- macOS 15+

## Package Targets

The package is split into three independently-testable library targets and three matching test targets.

### Library targets

| Target | What it owns | Depends on |
|---|---|---|
| `EnvTokenKit` | `EnvTokenProviding` protocol, `EnvTokenProvider` (env var + login-shell resolution), `EnvTokenProviderLoginShell` | — (no dependencies) |
| `OAuthTokenKit` | `TokenStore` protocol, `KeychainTokenStore`, `OAuthServicing` / `OAuthServiceProtocol`, `OAuthService`, `GitHubScopes`, `URLSessionProtocol` | — (no dependencies) |
| `GitHubClient` | `TokenCache`, `GitHubTransport`, `GitHubClient` facade, all API domain functions and models | `EnvTokenKit`, `OAuthTokenKit` |

### Test targets

| Target | What it tests |
|---|---|
| `EnvTokenKitTests` | `EnvTokenProvider` env-var resolution, shell latch behaviour, stub shell resolver |
| `OAuthTokenKitTests` | `OAuthService` OAuth flow and auth-state, `KeychainTokenStore` round-trip |
| `GitHubClientTests` | `TokenCache` resolution chain and store priority, `GitHubClient` facade wiring |

### Dependency and boundary rules

- `EnvTokenKit` and `OAuthTokenKit` are **peer targets** — neither depends on the other.
- `GitHubClient` uses `public import OAuthTokenKit` in both `GitHubClient.swift` (required because `GitHubClient.oauthService` names `OAuthServiceProtocol`) and `TokenCache.swift` (required because `TokenCache`'s public initialisers name `TokenStore`). `TokenCache.swift` also uses `public import EnvTokenKit` (required because `TokenCache`'s public initialisers name `EnvTokenProviding`). `GitHubClient.swift` uses `internal import EnvTokenKit` — sufficient because no `EnvTokenKit` type appears in that file's public declarations; `EnvTokenProvider` is constructed locally and immediately erased to `any EnvTokenProviding`. Swift import access is per-file; each file independently satisfies its own compiler requirement. Add `EnvTokenKit` as an explicit dependency only when you need to name `EnvTokenProvider` directly in your own code.
- `GitHubLogger` stays in `GitHubClient/Transport/`. The kits receive a `(@Sendable (String, String) -> Void)?` log closure bridged at wiring time in `GitHubClient.init` — they never import `GitHubLogger` directly.
- Consuming apps depend **only on `GitHubClient`**. `EnvTokenKit` and `OAuthTokenKit` are transitive; you do not add them as explicit dependencies unless you need to use their types directly.

## Installation

Add to your `Package.swift`:

```swift
.package(url: "https://github.com/runbot-hq/GitHubClient", branch: "main")
```

```swift
.target(
    name: "MyTarget",
    dependencies: [
        .product(name: "GitHubClient", package: "GitHubClient")
    ]
)
```

`OAuthTokenKit` is re-exported through `GitHubClient` via `public import` — you get `OAuthServiceProtocol`, `TokenStore`, `GitHubScopes`, and related types without a separate dependency. `EnvTokenKit` is partially re-exported through `GitHubClient` via `public import EnvTokenKit` in `TokenCache.swift` only: the `EnvTokenProviding` protocol is accessible to consumers because it appears in `TokenCache`'s public initialisers. The concrete `EnvTokenProvider` type is not re-exported and is not part of `GitHubClient`'s public surface. `GitHubClient.swift` itself uses `internal import EnvTokenKit` — `EnvTokenKit` types do not leak from that file. If you need to name `EnvTokenProvider` directly in your own code, add `EnvTokenKit` as an explicit dependency.

## Usage

The recommended entry point is the `GitHubClient` facade. It constructs and wires
`KeychainTokenStore`, `EnvTokenProvider`, `TokenCache`, `OAuthService`, and `GitHubTransport` in one call.

```swift
// AppDelegate or your app's composition root (@MainActor)
let github = GitHubClient(
    clientID: "your-client-id",
    clientSecret: "your-client-secret",
    service: "com.yourapp.github",
    account: "github-oauth-token",
    logger: MyLogger.shared
)

let oauth: any OAuthServiceProtocol = github.oauthService
let transport: any GitHubTransportProtocol = github.transport
```

For tests, inject protocol mocks directly:

```swift
let github = GitHubClient(
    oauthService: MockOAuthService(),
    transport: MockTransport()
)
```

## Usage Examples

### Fetch self-hosted runners for an org

```swift
import GitHubClient

// CI / automation — token picked up from GH_TOKEN / GITHUB_TOKEN automatically
let runners = await fetchRunners(scopeString: "orgs/acme")
for runner in runners ?? [] {
    print("\(runner.name) — \(runner.status) (busy: \(runner.busy))")
}
```

### Fetch active workflow runs for a repo

```swift
let scope = Scope.parse("repos/acme/my-repo")!

switch await fetchActiveRuns(scope: scope) {
case .success(let runs):
    for run in runs {
        print("[\(run.status)] \(run.name ?? "unnamed") — \(run.htmlUrl)")
    }
case .rateLimited(let partial):
    print("Rate-limited; \(partial.count) partial results returned")
case .noToken:
    print("No GitHub token configured — trigger OAuth sign-in")
case .authFailure:
    print("Token rejected by GitHub")
}
```

### Fetch jobs for a specific run

```swift
let jobs = await fetchJobs(runID: 12345678, scope: scope)
for job in jobs {
    let conclusion = job.conclusion ?? "in progress"
    print("  \(job.name): \(conclusion) (\(job.steps.count) steps)")
}
```

### Fetch a step log

```swift
if let log = await fetchStepLog(jobID: 987654, stepNumber: 2, scope: "repos/acme/my-repo") {
    print(log)
}
```

### Fetch user orgs and repos

```swift
let orgs = await fetchUserOrgs()
let repos = await fetchUserRepos()
print("Orgs: \(orgs)")
print("Repos: \(repos)")
```

### Testing with mock transport

```swift
// Inject a MockTransport — no Keychain, no network
let client = GitHubClient(
    oauthService: MockOAuthService(),
    transport: MockTransport()
)
let jobs = await fetchJobs(runID: 1, scope: .org("acme"), transport: client.transport)
XCTAssertEqual(jobs.count, 2)
```

### Testing token resolution (EnvTokenKit)

Inject a `StubEnvTokenProvider` via `TokenCache(tokenStore:envProvider:)` to control the env/shell path without spawning a real subprocess:

```swift
let stub = StubEnvTokenProvider(result: .found("test-token"))
let cache = TokenCache(tokenStore: MockTokenStore(), envProvider: stub)
let token = await cache.token()
// stub.callCount reflects exactly how many times token() was called
```

## Authentication

### Token resolution order

At every API call, the token is resolved in this order — first match wins:

1. **In-memory cache** — zero I/O; warmed on first successful resolution
2. **`TokenStore`** (Keychain by default via `KeychainTokenStore`) — synchronous `SecItemCopyMatching` read
3. **`GH_TOKEN` environment variable** — read via `ProcessInfo.processInfo.environment` (a snapshot captured at process launch); handled by `EnvTokenProvider` in `EnvTokenKit`
4. **`GITHUB_TOKEN` environment variable** — same; covers standard CI injection
5. **Login-shell fallback** — spawns `/bin/zsh -l -c 'echo $GH_TOKEN'`; cold Finder/Dock launch only

Steps 3–5 are handled by `EnvTokenProvider` (in `EnvTokenKit`). `TokenCache` delegates to it via the `EnvTokenProviding` protocol — it never names the concrete type directly.

> **Note — two env-var read paths:** `EnvTokenProvider` (steps 3–4 above) reads env vars via `ProcessInfo.processInfo.environment`, a snapshot fixed at process launch. `OAuthService.hasAnyToken` reads the same vars via `getenv()`, which reflects the live process environment. In production these are equivalent. In test harnesses that inject env vars after process launch (e.g. `setenv()` in test setUp), `hasAnyToken` will see the injected value but `TokenCache.token()` will not. This divergence is intentional and documented in `EnvTokenProvider.resolveFromEnvironment()`.

The cache is invalidated automatically after every sign-in and sign-out via the `onTokenSaved` / `onTokenDeleted` callbacks wired in `GitHubClient.init`.

### OAuth (interactive users)

```swift
if let url = github.oauthService.makeSignInURL() {
    NSWorkspace.shared.open(url)
}
// Forward the OAuth redirect callback from AppDelegate.application(_:open:):
github.oauthService.handleCallback(url)
```

### OAuth scopes

Scopes control what permissions are requested from the user during sign-in. Pass a `scopes:` array to `GitHubClient.init` using the typed constants in `GitHubScopes`.

**Default scopes** (used when `scopes:` is omitted):

| Constant | GitHub scope | Access granted |
|---|---|---|
| `GitHubScopes.repo` | `repo` | Full read/write access to code, commits, pull requests |
| `GitHubScopes.readOrg` | `read:org` | Read-only access to org membership and teams |
| `GitHubScopes.adminOrg` | `admin:org` | Full admin access to org membership and teams |
| `GitHubScopes.manageRunnersOrg` | `manage_runners:org` | Manage self-hosted runners in an org |
| `GitHubScopes.workflow` | `workflow` | Manage and trigger GitHub Actions workflows |

**Request only what you need** — for a read-only tool, narrow the scopes at init time:

```swift
let github = GitHubClient(
    clientID: "your-client-id",
    clientSecret: "your-client-secret",
    service: "com.yourapp.github",
    account: "github-oauth-token",
    scopes: [GitHubScopes.readOrg, GitHubScopes.repo]
)
```

**Extend the defaults** when you need an extra scope (e.g. reading user profile data):

```swift
let github = GitHubClient(
    clientID: "your-client-id",
    clientSecret: "your-client-secret",
    service: "com.yourapp.github",
    account: "github-oauth-token",
    scopes: GitHubScopes.default + [GitHubScopes.readUser]
)
```

See the [GitHub OAuth scopes documentation](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/scopes-for-oauth-apps) for the full list of available scopes.

### Checking auth state

> **Note (PR #75 behaviour change):** `isAuthenticated` previously returned `true` for any non-nil Keychain entry, including stored empty strings. It now returns `false` for empty strings — `tokenStore.load().map { !$0.isEmpty } ?? false`. If you have a corrupted Keychain entry (empty string stored), `isAuthenticated` will now correctly return `false`. Update any `MockOAuthService` stubs that returned `""` to represent a signed-in state.

```swift
// Keychain-only check (synchronous)
if github.oauthService.isAuthenticated {
    print("OAuth token present")
}

// Any usable token — Keychain OR env var (uses getenv(), not ProcessInfo snapshot)
if github.oauthService.hasAnyToken {
    print("A token is available from some source")
}
```

### Environment token (CI / automation)

Export `GH_TOKEN` or `GITHUB_TOKEN` — the library picks it up automatically with no additional configuration. `EnvTokenProvider` reads env vars from `ProcessInfo.processInfo.environment` (the snapshot captured at process launch), which is correct for standard CI runners where the environment is fixed before the process starts. `OAuthService.hasAnyToken` additionally checks the same vars via `getenv()` for a live read — see the note in [Token resolution order](#token-resolution-order) for the full divergence rationale.

## License

MIT
