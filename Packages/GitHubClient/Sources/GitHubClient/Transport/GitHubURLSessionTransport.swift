// GitHubURLSessionTransport.swift
// GitHubClient

import Foundation

// MARK: - GitHubTransport

/// The concrete `URLSession`-backed implementation of `GitHubTransportProtocol`.
///
/// `GitHubTransport` owns the decoder, encoder, session, rate-limiter, token-provider,
/// and call counter. Callers that need a real network transport use `currentTransport`;
/// tests inject a mock conformer or construct a custom instance via
/// `init(decoder:encoder:session:rateLimiter:tokenProvider:logger:callCounter:)`.
///
/// **Thread safety:** `GitHubTransport` is a value type whose `let` properties are either
/// value types or `Sendable` reference types. `JSONDecoder`/`JSONEncoder` are reference
/// types declared `@unchecked Sendable` by the standard library. They are safe for
/// concurrent reads because no mutable state is accessed after `init` — all configuration
/// (date decoding strategy, key decoding strategy, etc.) must be applied before the
/// transport is initialised and never changed afterwards. ⚠️ Do NOT mutate the decoder
/// or encoder after construction; doing so is an unsynchronised write that will corrupt
/// concurrent decodes/encodes.
public struct GitHubTransport: GitHubTransportProtocol {

  // MARK: - Stored properties

  /// JSON decoder — stateless after `init`, safe for concurrent reads.
  ///
  /// ⚠️ **Do not mutate the returned instance.** `JSONDecoder` is a reference type;
  /// mutating its properties after this transport has been initialised will corrupt
  /// concurrent decodes. Configure before passing to init and never touch it again.
  public let decoder: JSONDecoder

  /// JSON encoder — stateless after `init`, safe for concurrent reads.
  ///
  /// ⚠️ **Do not mutate the returned instance.** `JSONEncoder` is a reference type;
  /// mutating its properties after this transport has been initialised will corrupt
  /// concurrent encodes. Configure before passing to init and never touch it again.
  /// Kept `internal` (not `public`) because no caller outside this module needs to
  /// read the encoder directly; encoding is done internally by `post`, `put`, and
  /// `patchRunnerLabels`.
  internal let encoder: JSONEncoder

  /// URL session used for all network requests. Defaults to `URLSession.shared`.
  private let session: URLSession

  /// Rate-limit actor used to arm/clear the global back-off window.
  private let rateLimiter: any RateLimitActorProtocol

  /// Async closure that returns the current GitHub PAT, or `nil` when signed out.
  ///
  /// WHY A STORED ASYNC CLOSURE (not a direct `TokenCache` reference):
  /// 1. Decoupling: `GitHubTransport` lives in the `Transport` layer and must
  ///    not import `TokenCache` from the `Auth` layer — that would create a
  ///    circular dependency within the module. A closure erases the concrete type.
  /// 2. Testability: tests can inject a synchronous stub (`{ "test-token" }` or
  ///    `{ nil }`) without constructing a full `KeychainTokenStore`/`TokenCache`
  ///    stack. This is the primary reason the parameter exists in the public init.
  /// 3. Lazy resolution: the closure is awaited inside `execute()`, which is
  ///    already `async`. On a cold Finder/Dock launch the first await suspends
  ///    for ~50–200 ms while `TokenCache.token()` spawns a login shell. The
  ///    closure boundary makes that suspension point explicit and keeps it off
  ///    any actor's serial executor (execute() is `@concurrent`).
  /// 4. Future flexibility: the provider can be swapped (e.g. to a short-lived
  ///    installation token refresher) without changing `GitHubTransport`'s API.
  private let tokenProvider: @Sendable () async -> String?

  /// Optional logger for diagnostic messages.
  public let logger: (any GitHubLogger)?

  /// Call counter incremented once per completed HTTP round-trip (any status code).
  ///
  /// Incremented in `execute()` immediately after `session.data(for:)` returns,
  /// before `interpretHTTPResponse` branches on status code. Network errors
  /// (DNS failure, timeout — where no request left the machine) are excluded.
  ///
  /// Injected at init so tests can pass a mock conformer and assert call counts
  /// without touching the shared singleton. Defaults to `APICallCounter.shared`.
  private let callCounter: any APICallCounterProtocol

  /// The conditional GET (ETag) cache for this transport instance.
  /// Each `GitHubTransport` owns its own cache so that cache entries are
  /// scoped to the transport's lifetime and cleared when the token changes.
  private let conditionalGETCache = ConditionalGETCache()

  /// Cancellation-safe gate that limits the number of concurrent in-flight
  /// HTTP requests. Defaults to 4 simultaneous operations.
  private let requestGate: GitHubRequestGate

  // MARK: - Init
/// Endpoint diagnostics counter for completed HTTP responses.
  /// Counts every completed round-trip including 200, 304, 403, and 429.
  /// Reset with each `report()` call.
  private let endpointCounter: GitHubEndpointCounter

  /// Creates a `GitHubTransport` with the given dependencies.
  ///
  /// SOURCE-PACKAGE NOTE — `tokenProvider: async` is not an ABI break:
  /// `GitHubClient` is distributed as an SPM source package (no `type: .dynamic`
  /// in `Package.swift`). Every consumer recompiles from source, so there is no
  /// binary ABI to break. Additionally, Swift auto-promotes a synchronous
  /// `@Sendable () -> String?` closure to `@Sendable () async -> String?` at the
  /// call site — existing callers that pass a sync closure continue to compile
  /// without modification. No semver bump is required for this change.
  ///
  /// WHY `tokenProvider` HAS A `nil` DEFAULT:
  /// The `nil` default (resolved to `{ nil }` in the body) exists so that
  /// `GitHubTransport()` compiles in test and standalone contexts that do not
  /// have a `TokenCache` available. In production, `GitHubClient.init` always
  /// supplies an explicit `tokenProvider: { await cache.token() }` — the default
  /// is never used in a shipped app. A `GitHubTransport()` constructed without
  /// an explicit provider will return `.noToken` on every `execute()` call, which
  /// is the correct behaviour for an unauthenticated transport stub.
  ///
  /// ⚠️ Do NOT add `tokenProvider: { await TokenCache.shared.token() }` as the
  /// default — that would silently couple transport to a shared singleton and
  /// make token injection in tests impossible without swizzling.
  public init(
    decoder: JSONDecoder = JSONDecoder(),
    encoder: JSONEncoder = JSONEncoder(),
    session: URLSession = .shared,
    rateLimiter: some RateLimitActorProtocol = rateLimitActor,
    tokenProvider: (@Sendable () async -> String?)? = nil,
    logger: (any GitHubLogger)? = nil,
    callCounter: any APICallCounterProtocol = APICallCounter.shared,
    maxConcurrentRequests: Int = 4
  ) {
    self.decoder = decoder
    self.encoder = encoder
    self.session = session
    self.rateLimiter = rateLimiter
    self.tokenProvider = tokenProvider ?? { nil }
    self.logger = logger
    self.callCounter = callCounter
    self.requestGate = GitHubRequestGate(limit: maxConcurrentRequests)
    self.endpointCounter = GitHubEndpointCounter()
  }

  /// Internal init with endpoint counter injection for testing.
  ///
  /// - Note: Not public because `GitHubEndpointCounter` is internal. Tests in the
  ///   same module can use this to inject a test-doubled counter.
  internal init(
    decoder: JSONDecoder = JSONDecoder(),
    encoder: JSONEncoder = JSONEncoder(),
    session: URLSession = .shared,
    rateLimiter: some RateLimitActorProtocol = rateLimitActor,
    tokenProvider: (@Sendable () async -> String?)? = nil,
    logger: (any GitHubLogger)? = nil,
    callCounter: any APICallCounterProtocol = APICallCounter.shared,
    maxConcurrentRequests: Int = 4,
    endpointCounter: GitHubEndpointCounter
  ) {
    self.decoder = decoder
    self.encoder = encoder
    self.session = session
    self.rateLimiter = rateLimiter
    self.tokenProvider = tokenProvider ?? { nil }
    self.logger = logger
    self.callCounter = callCounter
    self.requestGate = GitHubRequestGate(limit: maxConcurrentRequests)
    self.endpointCounter = endpointCounter
  }

  // MARK: - Core execution

  /// Core execution pipeline shared by all `GitHubTransportProtocol` methods.
  ///
  /// Resolves the token (async — may spawn a login shell on cold Finder launch),
  /// builds a signed `URLRequest`, performs the `URLSession` round-trip, and maps
  /// the HTTP response to an `ExecuteResult`.
  ///
  /// - Parameters:
  ///   - endpoint: A fully-qualified URL string or a GitHub REST API path fragment
  ///     (resolved via `resolveURL(_:)`).
  ///   - timeout: Request timeout in seconds.
  ///   - logTag: A short prefix used in every log line emitted by this call
  ///     (e.g. `"apiAsync"`, `"post"`).
  ///   - useRawAccept: When `true`, sends `application/octet-stream` as the
  ///     `Accept` header instead of the default GitHub JSON media type.
  ///     Used by `raw(_:timeout:)` for endpoints that 302-redirect to S3.
  ///   - configure: An optional closure applied to the base `URLRequest` before
  ///     it is sent — used to set `httpMethod`, `httpBody`, etc.
  /// - Returns: An `ExecuteResult` describing the outcome of the round-trip.
  @concurrent
  func execute(
    _ endpoint: String,
    timeout: TimeInterval,
    logTag: String,
    useRawAccept: Bool = false,
    conditionalGET: Bool = false,
    configure: @Sendable (URLRequest) -> URLRequest = { $0 }
  ) async -> ExecuteResult {
    guard let token = await tokenProvider() else {
      logger?.log("\(logTag) › no token available", category: "transport")
      return .noToken
    }
    guard let baseReq = buildRequest(
      endpoint: endpoint,
      token: token,
      timeout: timeout,
      useRawAccept: useRawAccept,
      configure: configure,
      logTag: logTag
    ) else {
      return .networkError(URLError(.badURL))
    }

    let urlString = resolveURL(endpoint)

    // Conditional GET: look up the ETag cache and set If-None-Match header.
    let cachedEntry: ConditionalGETCache.Entry?
    var req = baseReq
    if conditionalGET {
      cachedEntry = await conditionalGETCache.entry(for: urlString, token: token)
      if let etag = cachedEntry?.etag {
        req.setValue(etag, forHTTPHeaderField: "If-None-Match")
        logger?.log(
          "\(logTag) › conditional GET with ETag: \(etag)",
          category: "transport")
      }
      // Ensure we bypass the system URLCache so that every conditional call
      // reaches GitHub's API and returns a fresh 304 or 200 with current headers.
      req.cachePolicy = .reloadIgnoringLocalCacheData
    } else {
      cachedEntry = nil
    }

    logger?.log(
      "\(logTag) › firing request: \(urlString) raw=\(useRawAccept) cachePolicy=\(req.cachePolicy.rawValue)",
      category: "transport")
    let request = req  // Capture for @Sendable closure below.
    do {
      let (data, response) = try await requestGate.withPermit {
        try await session.data(for: request)
      }

      // Record endpoint diagnostics for every completed HTTP round-trip,
      // including 304, 403, and 429. This must happen before branching on
      // status code so that all completed responses are represented.
      if let httpResponse = response as? HTTPURLResponse {
        await endpointCounter.record(url: urlString, statusCode: httpResponse.statusCode)
      }

      // Handle 304 Not Modified — return cached data without counting the call.
      if let httpResponse = response as? HTTPURLResponse,
         httpResponse.statusCode == 304,
         let cachedEntry {
        logger?.log(
          "\(logTag) › 304 Not Modified — returning cached data (\(cachedEntry.data.count) bytes)",
          category: "transport")
        // GitHub does not count a 304 against the API quota, so we do
        // NOT call callCounter.record(). Normalise the status code to 200
        // so that callers observing .success(statusCode:) do not need to
        // handle 304 as a special case — the cached representation is a
        // successful response.
        return .success(cachedEntry.data, statusCode: 200, linkHeader: cachedEntry.linkHeader)
      }

      // Count every completed HTTP round-trip regardless of status code.
      // 5xx, 4xx, and 2xx all consumed a quota slot on GitHub's side.
      // Network errors (DNS/timeout — no bytes sent) fall through to the
      // catch below and are correctly excluded.
      await callCounter.record()
      logger?.log(
        "\(logTag) › response received: \(urlString) bytes=\(data.count)",
        category: "transport")
      let result = await interpretHTTPResponse(
        response, data: data, urlString: urlString, logTag: logTag
      )

      // If the response was successful and carried an ETag, cache it for
      // future conditional GETs. Only cache when conditionalGET is enabled
      // so that raw ZIP downloads or non-conditional responses never populate
      // the cache with a representation that could be confused with a JSON
      // response to the same URL.
      if conditionalGET,
         case .success = result,
         let httpResponse = response as? HTTPURLResponse,
         let etag = httpResponse.value(forHTTPHeaderField: "ETag") {
        let linkHeader = httpResponse.value(forHTTPHeaderField: "Link")
        let entry = ConditionalGETCache.Entry(
          etag: etag,
          data: data,
          linkHeader: linkHeader
        )
        await conditionalGETCache.store(entry, for: urlString, token: token)
        logger?.log(
          "\(logTag) › cached ETag: \(etag)",
          category: "transport")
      }

      return result
    } catch {
      logger?.log(
        "\(logTag) › \(urlString) network error: \(error.localizedDescription)",
        category: "transport")
      return .networkError(error)
    }
  }

  // MARK: - Request building

  /// Builds a signed `URLRequest` for `endpoint`, or `nil` if the URL is invalid.
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
      logger?.log("\(logTag) › invalid URL: \(urlString)", category: "transport")
      return nil
    }
    let base =
      useRawAccept
      ? makeRawRequest(url: url, token: token, timeout: timeout)
      : makeRequest(url: url, token: token, timeout: timeout)
    return configure(base)
  }

  // MARK: - HTTP response interpretation

  /// Maps an HTTP response + body into an `ExecuteResult`, arming rate-limit back-off as needed.
  ///
  /// `callCounter.record()` is called in `execute()` before this method is reached —
  /// once per completed HTTP round-trip regardless of status code.
  private func interpretHTTPResponse(
    _ response: URLResponse,
    data: Data,
    urlString: String,
    logTag: String
  ) async -> ExecuteResult {
    guard let http = response as? HTTPURLResponse else {
      logger?.log("\(logTag) › \(urlString) response was not HTTPURLResponse — treating as network error", category: "transport")
      return .networkError(URLError(.badServerResponse))
    }
    logger?.log(
      "\(logTag) › \(urlString) HTTP \(http.statusCode) bytes=\(data.count)",
      category: "transport")
    if http.statusCode == 403 || http.statusCode == 429 {
      let wasRateLimited = await handleRateLimitResponse(
        statusCode: http.statusCode,
        data: data,
        response: http,
        endpoint: urlString,
        rateLimiter: rateLimiter,
        logger: logger
      )
      logger?.log(
        "\(logTag) › \(urlString) HTTP \(http.statusCode) → \(wasRateLimited ? "rateLimited" : "permissionDenied")",
        category: "transport")
      return wasRateLimited ? .rateLimited : .permissionDenied
    }
    guard (200..<300).contains(http.statusCode) else {
      logErrorBody(data, endpoint: urlString, status: http.statusCode, logger: logger)
      return .httpError(http.statusCode)
    }
    await rateLimiter.clearIfNotLimited()
    if let remaining = http.value(forHTTPHeaderField: "X-RateLimit-Remaining").flatMap(Int.init) {
        await rateLimiter.updateRemaining(remaining)
    }
    let linkHeader = http.value(forHTTPHeaderField: "Link")
    return .success(data, statusCode: http.statusCode, linkHeader: linkHeader)
  }
}

// MARK: - Shared execution core

/// The result of a single `URLSession` round-trip through `execute(_:timeout:logTag:useRawAccept:configure:)`.
///
/// Returned by the internal `execute` method and pattern-matched by every public
/// transport method (`apiAsync`, `post`, `delete`, etc.) to map HTTP outcomes to
/// their respective return types. Keeping this type `internal` prevents leaking
/// transport-layer concerns into callers outside the module.
internal enum ExecuteResult {
  /// A 2xx response with body, status code, and optional `Link` header.
  case success(Data, statusCode: Int, linkHeader: String?)
  /// No GitHub token was available — user is signed out or no env var is set.
  case noToken
  /// A non-2xx HTTP status code was returned.
  case httpError(Int)
  /// The request was rate limited (403/429 with rate-limit signals).
  case rateLimited
  /// The request was denied (403/429 without rate-limit signals).
  case permissionDenied
  /// A transport-level network error occurred (DNS failure, TLS error, timeout, etc.).
  case networkError(Error)
}
