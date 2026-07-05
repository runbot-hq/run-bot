# swift-github-client

A lightweight, modern Swift GitHub API client for macOS apps. Direct REST calls over `URLSession`, zero external dependencies, Swift 6.2 strict concurrency throughout.

## Features

- **Dual authentication** — OAuth Authorization Code flow for interactive users; `GH_TOKEN` / `GITHUB_TOKEN` env var for CI and automation. Same call site, no branching
- **Layered token resolution** — memory cache → Keychain → env var, resolved at call time
- **Direct REST over `URLSession`** — no code generation, no auto-generated OpenAPI types, no third-party networking layer
- **Rate-limit aware** — automatic backoff and retry on 429 / 403 rate-limit responses
- **Link-header pagination** — cursor-based pagination handled transparently
- **`KeychainTokenStore` built in** — ready-made Keychain integration via `Security.framework`; swap in a mock for tests via the `TokenStore` protocol
- **Swift 6.2 strict concurrency** — no `@unchecked Sendable`, compiler-enforced boundaries throughout
- **Testable by design** — every concrete type hidden behind a protocol; inject a fake transport or token store in tests with no Keychain involvement

## Requirements

- Swift 6.2+
- macOS 26+ (Tahoe SDK)

## Installation

> **Note:** Standalone SPM extraction is planned (tracked in step 14 of the extraction
> roadmap). Until then, `GitHubClient` is a local SPM target inside the `run-bot`
> monorepo. Add it as a local dependency:

```swift
// Package.swift
.package(path: "../run-bot")  // or embed directly in your workspace
```

```swift
.target(
    name: "MyApp",
    dependencies: [
        .product(name: "GitHubClient", package: "run-bot")
    ]
)
```

Once extracted to its own repo the import will become:

```swift
.package(url: "https://github.com/runbot-hq/swift-github-client", from: "1.0.0")
```

## Usage

The recommended entry point is the `GitHubClient` facade. It constructs and wires
`KeychainTokenStore`, `TokenCache`, `OAuthService`, and `GitHubTransport` in one call —
`TokenCache.invalidate()` is called automatically after every sign-in and sign-out.

```swift
// AppDelegate or your app's composition root (@MainActor)
let github = GitHubClient(
    clientID: "your-client-id",
    clientSecret: "your-client-secret",
    service: "com.yourapp.github",      // Keychain service name
    account: "github-oauth-token",      // Keychain account name
    logger: MyLogger.shared
)

// Access the wired subsystems
let oauth: any OAuthServiceProtocol = github.oauthService
let transport: any GitHubTransportProtocol = github.transport
```

In `applicationDidFinishLaunching`, wire the transport shims and the shared logger
so that free-function diagnostics (`ghPost`, `fetchStepLog`, etc.) are not silently
dropped. `sharedGitHubTransport` and `github.transport` are separate instances —
without `configureGHLogger` the logger on the singleton remains `nil` for the process
lifetime.

```swift
let transport = github.transport
// transport.logger is (any GitHubLogger)? — only wire if one was supplied at init.
if let logger = transport.logger {
    configureGHLogger(logger)          // wire shim-layer logger
}
configureGHAPI { endpoint in
    await transport.apiAsync(endpoint)
}
configureGHRaw { endpoint in
    await transport.raw(endpoint)
}
configureGHAPIPaginated { endpoint, timeout in
    await transport.apiPaginated(endpoint, timeout: timeout)
}
```

For tests, inject protocol mocks directly — no Keychain or network involved:

```swift
let github = GitHubClient(
    oauthService: MockOAuthService(),
    transport: MockTransport()
)
```

## Authentication

### OAuth token (interactive users)

The user clicks "Sign in with GitHub" in your app. The library opens a browser URL,
GitHub redirects back with a `code`, and the library exchanges it for an access token
via the OAuth Authorization Code flow. The token is persisted in Keychain via
`KeychainTokenStore` and cached in memory for the session. Using the facade, this is
already wired — you only need to forward the callback URL:

```swift
// Open the sign-in URL in the browser
if let url = github.oauthService.makeSignInURL() {
    NSWorkspace.shared.open(url)
}

// In your AppDelegate / scene delegate, forward the OAuth redirect:
github.oauthService.handleCallback(url)
```

### CLI / environment token (`GH_TOKEN`, `GITHUB_TOKEN`)

A pre-existing Personal Access Token (PAT) passed via environment variable. No
configuration needed — the library picks it up automatically. Common in three scenarios:

- **CI pipelines** — GitHub Actions injects `GITHUB_TOKEN` automatically for the current run
- **Local scripts / automation** — developers export `GH_TOKEN` in their shell profile
- **Development / testing** — skip the full OAuth flow during development

### Resolution order

At every API call, the token is resolved in this order — first match wins:

1. In-memory cache
2. `TokenStore` (Keychain by default)
3. `GH_TOKEN` environment variable
4. `GITHUB_TOKEN` environment variable

### Bring your own token store

```swift
extension MyCustomStore: TokenStore {
    nonisolated func load() -> String? { ... }
    nonisolated func save(_ token: String) -> Bool { ... }
    nonisolated func delete() -> Bool { ... }
}

// Pass it to the facade or wire it directly into TokenCache:
let cache = TokenCache(tokenStore: MyCustomStore(), logger: MyLogger.shared)
```

## Making API calls

Use `github.transport` directly for authenticated requests:

```swift
// GET — returns raw Data? on success
let data = await github.transport.apiAsync("/repos/owner/repo/actions/runs")

// POST
let result = await github.transport.post("/repos/owner/repo/actions/runs/\(runID)/cancel")

// Paginated GET — follows Link headers, returns all pages concatenated
let data = await github.transport.apiPaginated("/orgs/my-org/actions/runners")

// Cancel a workflow run — returns true if the cancel request was accepted
let cancelled: Bool = await github.transport.cancelRun(runID: 12345, scope: "owner/repo")

// Patch runner labels — returns the updated label name strings, or nil on failure
let labels: [String]? = await github.transport.patchRunnerLabels(
    scope: "owner/repo",
    runnerID: 42,
    labels: ["self-hosted", "macOS"]
)
```

## Handling failures

All transport methods return `nil` (or `false` for booleans) on any failure — network
error, auth failure, rate limit, or malformed response. The transport logs the reason
via `GitHubLogger` before returning. For callers that need to distinguish failure modes
at the raw transport level, use `fetchActiveRuns` which returns a typed
`GitHubRunsFetchResult` instead of `nil`.

```swift
// Raw transport — nil means "something went wrong", check logs for detail
let  Data? = await github.transport.apiAsync("/repos/owner/repo/actions/runs")
guard let data else { return }  // logged internally

// Typed result — distinguish auth failure from rate limit from missing token
let result = await fetchActiveRuns(scope: .org("acme"))
switch result {
case .success(let runs):       break
case .rateLimited(let runs):   // partial — back off and retry
case .authFailure:             // token rejected — prompt re-auth
case .noToken:                 // not configured — check setup
}
```

## Runners

```swift
// Fetch all runners for a scope
let runners: [GitHubRunner] = await fetchRunners(scope: .repo(owner: "acme", name: "my-app"))
let runners: [GitHubRunner] = await fetchRunners(scope: .org("acme"))

// Convenience overload with a raw scope string
let runners: [GitHubRunner]? = await fetchRunners(scopeString: "orgs/acme")
```

## Workflow Runs & Jobs

```swift
// Fetch active (queued + in_progress) runs — typed result handles all failure modes
// Note: GitHubRunsFetchResult is provisional; a richer ExecuteResult type is
// tracked in #1950 and will replace this enum in a future PR.
let result = await fetchActiveRuns(scope: .org("acme"))
switch result {
case .success(let runs):      // all runs collected
case .rateLimited(let runs):  // partial — rate limit hit mid-fetch, runs collected so far are valid
case .authFailure:            // token rejected — discard everything
case .noToken:                // no token configured
}

// Fetch all jobs for a specific workflow run
let jobs: [GitHubJob] = await fetchJobs(runID: 12345678, scope: .repo(owner: "acme", name: "my-app"))

// Raw API types stay in GitHubClient.
let job: GitHubJob = jobs[0]
print(job.status)       // "in_progress" — raw string from GitHub
print(job.runnerName)   // "my-runner-1"
print(job.steps.count)  // number of steps
```

## API type ownership

`GitHubClient` owns the GitHub API shapes. `RunBotCore` adds app-specific behavior in
extensions and thin wrappers rather than duplicating API structs.

- `GitHubRunner`, `GitHubJob`, and `GitHubStep` are the single source of truth for GitHub fields.
- App-only concerns such as parsed dates, display helpers, derived status, and UI state live outside this module.
- A GitHub field change should require one API-type edit here, not mirrored edits in app targets.

## Bring your own logger

Conform any type to `GitHubLogger`. The `category` parameter is a free string
(e.g. `"auth"`, `"transport"`, `"keychain"`) — use it to filter log output:

```swift
extension MyLogger: GitHubLogger {
    nonisolated func log(_ message: String, category: String) {
        // Filter by category for focused diagnostics:
        // "auth"      — OAuthService, TokenCache, KeychainTokenStore
        // "transport" — GitHubTransport request/response pipeline
        os_log("%{public}@ [%{public}@]", log: .default, type: .debug, message, category)
    }
}
```

## Architecture

```
Sources/GitHubClient/
├── GitHubClient.swift                    ← facade: production + test inits
├── Protocols/
│   ├── TokenStore.swift                  ← persist/load tokens; inject your own or use KeychainTokenStore
│   └── GitHubLogger.swift                ← log sink; nonisolated for cross-actor transport calls
├── Auth/
│   ├── OAuthService.swift                ← Authorization Code flow, CSRF protection
│   ├── OAuthServiceProtocol.swift
│   └── TokenCache.swift                  ← memory cache → TokenStore → env var resolution
├── Transport/
│   ├── GitHubTransportProtocol.swift
│   ├── GitHubURLSessionTransport.swift   ← URLSession, rate-limit backoff, ExecuteResult pipeline
│   ├── GitHubTransport+Conformance.swift ← apiPaginated, post, put, delete, cancelRun, etc.
│   ├── GitHubTransportShim.swift         ← TransportBox, configureGHAPI/Raw/Paginated/Logger hooks
│   └── GitHubTransportShims.swift        ← module-level free-function shims (ghAPI, ghPost, …) + sharedGitHubTransport singleton
└── API/
    ├── GitHubScope.swift                 ← Scope enum: .repo(owner:name:) or .org(String)
    ├── GitHubConstants.swift
    ├── GitHubRequestBuilder.swift
    ├── GitHubResponseDecoder.swift
    ├── GitHubRateLimitHandler.swift
    ├── GitHubURLHelpers.swift
    ├── GitHubHelpers.swift               ← fetchUserRepos, fetchUserOrgs, fetchStepLog
    ├── GitHubRunnerAPI.swift             ← GitHubRunner / GitHubRunnerLabel + runner fetch APIs
    ├── GitHubWorkflowAPI.swift           ← GitHubWorkflowRun / GitHubJob / GitHubStep + workflow/job fetch APIs
    ├── APICallCounter.swift
    ├── AnyJSON.swift                     ← type-erased Codable for pagination accumulation
    └── KeychainTokenStore.swift          ← concrete TokenStore backed by Security.framework
```

The library has no opinion on how you log — inject any type conforming to `GitHubLogger`.
Token storage defaults to `KeychainTokenStore` but any `TokenStore` conformance works.

`GitHubClient` intentionally owns the raw GitHub API models. Higher-level modules can add
computed properties or app-specific wrappers, but they should not redefine the same runner,
workflow, job, or step fields in parallel.

## Type inventory

| Type | File | Description |
|---|---|---|
| `GitHubClient` | `GitHubClient.swift` | Facade — wires all subsystems |
| `GitHubScope` | `GitHubScope.swift` | `.repo(owner:name:)` or `.org(String)` |
| `GitHubRunner` | `GitHubRunnerAPI.swift` | Decoded runner object from the REST API |
| `GitHubRunnerLabel` | `GitHubRunnerAPI.swift` | Label attached to a `GitHubRunner` |
| `GitHubWorkflowRun` | `GitHubWorkflowAPI.swift` | Single workflow run (queued or in-progress) |
| `GitHubJob` | `GitHubWorkflowAPI.swift` | Individual job within a workflow run |
| `GitHubStep` | `GitHubWorkflowAPI.swift` | Step within a `GitHubJob` |
| `GitHubRunsFetchResult` | `GitHubWorkflowAPI.swift` | Typed fetch outcome: `.success`, `.rateLimited`, `.authFailure`, `.noToken` |
| `TokenCache` | `Auth/TokenCache.swift` | Layered token resolver (memory → Keychain → env) |
| `KeychainTokenStore` | `API/KeychainTokenStore.swift` | Concrete `TokenStore` via `Security.framework` |

## Why not the official GitHub SDK?

GitHub has no official Swift SDK. The only community option,
[`nerdishbynature/octokit.swift`](https://github.com/nerdishbynature/octokit.swift),
is effectively unmaintained and predates Swift 6 strict concurrency.

This library makes GitHub REST API calls directly over `URLSession` — no code generation,
no auto-generated OpenAPI types, no third-party networking dependencies. The entire
transport layer is ~200 lines behind a protocol, which means it's straightforward to
swap in a fake for tests or inspect exactly what's going on.

The other reason we built this rather than adopting an existing library is the dual
authentication pattern described above — no existing Swift library models the layered
resolution chain that macOS GitHub apps actually need.

## Alternatives

**[nerdishbynature/octokit.swift](https://github.com/nerdishbynature/octokit.swift)** —
the most complete community Swift GitHub client. Supports GitHub and GitHub Enterprise,
handles both token and OAuth configurations. Last active 2024; not yet updated for
Swift 6 strict concurrency. Worth evaluating if you don't need the dual auth resolution
chain or prefer a broader API surface.

## License

MIT
