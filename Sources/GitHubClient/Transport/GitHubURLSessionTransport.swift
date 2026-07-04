// GitHubURLSessionTransport.swift
// GitHubClient

import Foundation

// MARK: - GitHubTransport

/// The concrete `URLSession`-backed implementation of `GitHubTransportProtocol`.
///
/// `GitHubTransport` owns the decoder, encoder, session, rate-limiter, and token-provider.
/// Callers that need a real network transport use `sharedGitHubTransport`; tests
/// inject a mock conformer or construct a custom instance via
/// `init(decoder:encoder:session:rateLimiter:tokenProvider:)`.
///
/// **Thread safety:** `GitHubTransport` is a value type whose `let` properties are either
/// value types or `Sendable` reference types. `JSONDecoder`/`JSONEncoder` are reference types
/// but are `@unchecked Sendable` and stateless after `init`, safe for concurrent reads.
/// Concurrent reads are safe; there is no mutable state.
public struct GitHubTransport: GitHubTransportProtocol {

  // MARK: - Stored properties

  /// JSON decoder — stateless after `init`, safe for concurrent reads.
  /// Kept as a stored `let` (one allocation per `GitHubTransport` instance)
  /// rather than per-call-site to avoid repeated allocations while remaining
  /// functionally identical to a local instance in every call site.
  ///
  /// - Note: `internal` (not `private`) because `GitHubTransport+Conformance.swift`
  ///   accesses it from a cross-file extension in the same module. This is a known
  ///   Swift limitation: `private` does not cross file boundaries within an extension.
  internal let decoder: JSONDecoder

  /// JSON encoder — stateless after `init`, safe for concurrent reads.
  /// Same rationale as `decoder`.
  ///
  /// - Note: `internal` for the same cross-file extension reason as `decoder`.
  internal let encoder: JSONEncoder

  /// URL session used for all network requests. Defaults to `URLSession.shared`.
  /// Tests inject a custom session (e.g. via `URLProtocol` subclassing) to stub
  /// network responses without hitting the real GitHub API.
  private let session: URLSession

  /// Rate-limit actor used to arm/clear the global back-off window.
  /// Defaults to the module-level `rateLimitActor` singleton so existing
  /// production behaviour is preserved without any call-site changes.
  private let rateLimiter: any RateLimitActorProtocol

  /// Synchronous closure that returns the current GitHub PAT, or `nil` when
  /// the user is signed out. Defaults to `githubTokenCore()` from
  /// `GitHubTransportShim` so the token pipeline is unchanged at launch.
  private let tokenProvider: @Sendable () -> String?

  // MARK: - Init

  /// Creates a `GitHubTransport` with the given dependencies. All parameters have defaults
  /// that reproduce the production behaviour, so `GitHubTransport()` is ready to use.
  ///
  /// - Parameters:
  ///   - decoder: JSON decoder instance. Defaults to a fresh `JSONDecoder()`.
  ///   - encoder: JSON encoder instance. Defaults to a fresh `JSONEncoder()`.
  ///   - session: URL session for all network requests. Defaults to `URLSession.shared`.
  ///   - rateLimiter: Rate-limit actor. Defaults to the shared `rateLimitActor`.
  ///   - tokenProvider: Closure returning the current GitHub PAT or `nil`.
  ///     Defaults to `githubTokenCore()` from `GitHubTransportShim`.
  public init(
    decoder: JSONDecoder = JSONDecoder(),
    encoder: JSONEncoder = JSONEncoder(),
    session: URLSession = .shared,
    rateLimiter: some RateLimitActorProtocol = rateLimitActor,
    tokenProvider: (@Sendable () -> String?)? = nil
  ) {
    self.decoder = decoder
    self.encoder = encoder
    self.session = session
    self.rateLimiter = rateLimiter
    self.tokenProvider = tokenProvider ?? { githubTokenCore() }
  }

  // MARK: - Core execution

  /// Core execution pipeline shared by all `GitHubTransportProtocol` methods.
  ///
  /// Single shared token-guard → URL-resolve → send → handle-response pipeline
  /// used by all `GitHubTransportProtocol` methods on this struct.
  ///
  /// Mirrors the module-level `urlSessionExecute` free function exactly, but
  /// reads `tokenProvider`, `rateLimiter` from `self` instead of module globals.
  ///
  /// - Parameters:
  ///   - endpoint: Relative path or absolute URL string.
  ///   - timeout: `URLRequest.timeoutInterval` for this request.
  ///   - logTag: Short prefix for all `log()` calls within the function.
  ///   - useRawAccept: When `true`, sets the raw-bytes `Accept` header instead
  ///     of the standard JSON header. Required for log endpoints that redirect to S3.
  ///   - configure: Closure applied to the pre-built `URLRequest` before sending.
  ///     Defaults to the identity closure. Must be `@Sendable`.
  @concurrent
  func execute(
    _ endpoint: String,
    timeout: TimeInterval,
    logTag: String,
    useRawAccept: Bool = false,
    configure: @Sendable (URLRequest) -> URLRequest = { $0 }
  ) async -> ExecuteResult {
    guard let token = tokenProvider() else {
      log("\(logTag) › no token available", category: .transport)
      return .noToken
    }
    guard let req = buildRequest(
      endpoint: endpoint,
      token: token,
      timeout: timeout,
      useRawAccept: useRawAccept,
      configure: configure,
      logTag: logTag
    ) else {
      return .networkError(URLError(.badURL))
    }
    do {
      let (data, response) = try await session.data(for: req)
      return await interpretHTTPResponse(
        response, data: data, urlString: resolveURL(endpoint)
      )
    } catch {
      log(
        "\(logTag) › \(resolveURL(endpoint)) network error: \(error.localizedDescription)",
        category: .transport)
      return .networkError(error)
    }
  }

  // MARK: - Request building

  /// Resolves `endpoint` to an absolute URL string, builds the typed `URLRequest`,
  /// applies `configure`, and logs + returns `nil` if the URL is malformed.
  private func buildRequest(
    endpoint: String,
    token: String,
    timeout: TimeInterval,
    useRawAccept: Bool,
    configure: @Sendable (URLRequest) -> URLRequest,
    logTag: String
  ) -> URLRequest? {
    let urlString = resolveURL(endpoint)
    guard let url = URL(string: urlString) else {
      log("\(logTag) › invalid URL: \(urlString)", category: .transport)
      return nil
    }
    let base =
      useRawAccept
      ? makeRawRequest(url: url, token: token, timeout: timeout)
      : makeRequest(url: url, token: token, timeout: timeout)
    return configure(base)
  }

  // MARK: - HTTP response interpretation

  /// Interprets a completed HTTP response, handling rate-limit, non-2xx, and
  /// success cases. Extracted from `execute` to reduce its cyclomatic complexity.
  ///
  /// - Parameters:
  ///   - response: The raw `URLResponse` returned by `URLSession`.
  ///   - data: The response body.
  ///   - urlString: The resolved absolute URL string used only for logging.
  private func interpretHTTPResponse(
    _ response: URLResponse,
    data: Data,
    urlString: String
  ) async -> ExecuteResult {
    guard let http = response as? HTTPURLResponse else {
      return .networkError(URLError(.badServerResponse))
    }
    if http.statusCode == 403 || http.statusCode == 429 {
      // Use the Bool return value from handleRateLimitResponse to classify
      // this response directly from its headers — never from the actor state.
      // Reading the actor after the call is a TOCTOU: a prior concurrent
      // request may have already armed the actor, causing a plain
      // permission-denied 403 (no rate-limit headers) to be misclassified
      // as .rateLimited instead of .permissionDenied.
      let wasRateLimited = await handleRateLimitResponse(
        statusCode: http.statusCode, data, response: http,
        endpoint: urlString, rateLimiter: rateLimiter
      )
      return wasRateLimited ? .rateLimited : .permissionDenied
    }
    guard (200..<300).contains(http.statusCode) else {
      logErrorBody(data, endpoint: urlString, status: http.statusCode)
      return .httpError(http.statusCode)
    }
    // Clear the rate-limit flag after a successful 2xx response, but only
    // when the actor is not currently limited. A single `clearIfNotLimited()`
    // call performs the check and the clear in one atomic actor hop, eliminating
    // the TOCTOU window that existed with the old snapshot+clear two-hop pattern.
    await rateLimiter.clearIfNotLimited()
    let linkHeader = http.value(forHTTPHeaderField: "Link")
    return .success(data, statusCode: http.statusCode, linkHeader: linkHeader)
  }
}

// MARK: - Shared execution core

/// The result of a single URLSession round-trip through `execute`.
internal enum ExecuteResult {
  /// 2xx response with optional body data (empty `Data()` for 204 No Content).
  ///
  /// `linkHeader` carries the raw `Link:` response header value used by paginated callers
  /// to discover the next-page URL. Non-paginated callers (e.g. `apiAsync`,
  /// `post`) always receive `nil` here and destructure with `_` — this is
  /// intentional. A split into `success` / `successPaginated` was considered but deferred:
  /// the single case keeps `execute` callers uniform and the `nil` default is
  /// always correct for endpoints that do not emit a `Link` header.
  case success(Data, statusCode: Int, linkHeader: String?)
  /// No GitHub token is currently available — the token provider returned `nil`.
  /// Distinct from `.networkError` and `.httpError(401)` so callers can treat
  /// "never had a token" separately from "token was valid but rejected by GitHub".
  ///
  /// - Note: Non-paginated callers (`apiAsync`, `post`,
  ///   `put`, `raw`) use `guard case .success` and therefore
  ///   treat `.noToken` identically to every other non-success result — a `nil`
  ///   return. Only `apiPaginated` pattern-matches this case explicitly,
  ///   to discard any partially collected items and return `nil` rather than partial
  ///   results. If you add a new call site that needs to distinguish "never had a
  ///   token" from other failures, match `.noToken` directly instead of relying on
  ///   the `guard case .success` collapse.
  case noToken
  /// Non-2xx response that is not a rate-limit or permission error; the request failed.
  case httpError(Int)
  /// 403 or 429 that triggered the rate-limit actor (genuine rate limit).
  /// Covers both the case where this request freshly armed the actor and the case
  /// where the actor was already armed by a concurrent caller — callers treat both
  /// identically (back off and retry).
  case rateLimited
  /// 403 that did NOT trigger the rate-limit actor — token scope, revoked PAT, or
  /// repo access denial. The actor is not armed; the token needs attention.
  case permissionDenied
  /// Network-level error (timeout, no connectivity, etc.).
  case networkError(Error)
}
