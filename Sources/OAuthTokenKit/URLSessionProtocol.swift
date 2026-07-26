// URLSessionProtocol.swift
// GitHubClient
import Foundation

// MARK: - URLSessionProtocol

/// Minimal seam over `URLSession` so tests can inject a fake without subclassing.
///
/// `URLSession.data(for:)` is declared in a Foundation extension and is therefore
/// not `open` — it cannot be overridden in a subclass defined outside the module.
/// Using a protocol instead avoids that restriction entirely.
///
/// ## Why this lives in OAuthTokenKit and not a shared module
/// `URLSessionProtocol` is used exclusively by `OAuthService` for token-exchange
/// network calls. It lives here rather than in a shared transport layer because no
/// other current target needs it — `GitHubTransport` in `GitHubClient` has its own
/// networking layer and does not use this seam.
///
/// If `GitHubTransport` ever needs a `URLSession` mock seam, it should define its
/// own protocol in `GitHubClient` rather than importing `OAuthTokenKit` for this
/// type alone. Importing `OAuthTokenKit` into `GitHubTransport` solely for a
/// two-line protocol would create a peer-target coupling with no architectural
/// justification. The duplication of a two-line protocol is the correct trade-off.
/// If a shared networking layer is ever introduced as a separate SPM target, both
/// protocols can be consolidated there at that point.
public protocol URLSessionProtocol: Sendable {
    /// Fetches the contents of a URL request and returns the data.
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

// MARK: - URLSession + URLSessionProtocol

/// Retroactive conformance of `URLSession` to `URLSessionProtocol`.
///
/// `URLSessionProtocol` is declared in this module (`OAuthTokenKit`), so
/// `@retroactive` does not apply here — Swift only requires that annotation
/// when *neither* the protocol nor the conforming type is defined in the
/// current module. `URLSession` is from Foundation; the protocol is ours.
/// The conformance is safe: `URLSession.data(for:)` already exists as a
/// Foundation method; we are only declaring that `URLSession` satisfies a
/// protocol we define.
extension URLSession: URLSessionProtocol {}
