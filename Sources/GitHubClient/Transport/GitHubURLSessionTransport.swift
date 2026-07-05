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
  internal let decoder: JSONDecoder

  /// JSON encoder — stateless after `init`, safe for concurrent reads.
  internal let encoder: JSONEncoder

  /// URL session used for all network requests. Defaults to `URLSession.shared`.
  private let session: URLSession

  /// Rate-limit actor used to arm/clear the global back-off window.
  private let rateLimiter: any RateLimitActorProtocol

  /// Synchronous closure that returns the current GitHub PAT, or `nil` when
  /// the user is signed out.
  private let tokenProvider: @Sendable () -> String?

  /// Optional logger for diagnostic messages.
  ///
  /// `internal` (not `private`) so the `GitHubTransportProtocol` conformance in
  /// `GitHubTransport+Conformance.swift` — a same-module extension in another
  /// file — can emit diagnostics through it.
  public let logger: (any GitHubLogger)?

  // MARK: - Init

  /// Creates a `GitHubTransport` with the given dependencies. All parameters have defaults
  /// that reproduce the production behaviour, so `GitHubTransport()` is ready to use.
  ///
  /// - Note: In production, `GitHubClient.init` always supplies an explicit `tokenProvider`
  ///   (`{ cache.token() }`) so the `nil` default is never used in the app target.
  ///   The default (`{ nil }`) exists only so `GitHubTransport()` compiles without
  ///   a token provider in test or standalone contexts where no `TokenCache` is wired.
  public init(
    decoder: JSONDecoder = JSONDecoder(),
    encoder: JSONEncoder = JSONEncoder(),
    session: URLSession = .shared,
    rateLimiter: some RateLimitActorProtocol = rateLimitActor,
    tokenProvider: (@Sendable () -> String?)? = nil,
    logger: (any GitHubLogger)? = nil
  ) {
    self.decoder = decoder
    self.encoder = encoder
    self.session = session
    self.rateLimiter = rateLimiter
    self.tokenProvider = tokenProvider ?? { nil }
    self.logger = logger
  }

  // MARK: - Core execution

  /// Core execution pipeline shared by all `GitHubTransportProtocol` methods.
  @concurrent
  func execute(
    _ endpoint: String,
    timeout: TimeInterval,
    logTag: String,
    useRawAccept: Bool = false,
    configure: @Sendable (URLRequest) -> URLRequest = { $0 }
  ) async -> ExecuteResult {
    guard let token = tokenProvider() else {
      logger?.log("\(logTag) › no token available", category: "transport")
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
      logger?.log(
        "\(logTag) › \(resolveURL(endpoint)) network error: \(error.localizedDescription)",
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
  private func interpretHTTPResponse(
    _ response: URLResponse,
    data: Data,
    urlString: String
  ) async -> ExecuteResult {
    guard let http = response as? HTTPURLResponse else {
      return .networkError(URLError(.badServerResponse))
    }
    if http.statusCode == 403 || http.statusCode == 429 {
      let wasRateLimited = await handleRateLimitResponse(
        statusCode: http.statusCode,
        data: data,
        response: http,
        endpoint: urlString,
        rateLimiter: rateLimiter,
        logger: logger
      )
      return wasRateLimited ? .rateLimited : .permissionDenied
    }
    guard (200..<300).contains(http.statusCode) else {
      logErrorBody(data, endpoint: urlString, status: http.statusCode, logger: logger)
      return .httpError(http.statusCode)
    }
    await rateLimiter.clearIfNotLimited()
    let linkHeader = http.value(forHTTPHeaderField: "Link")
    return .success(data, statusCode: http.statusCode, linkHeader: linkHeader)
  }
}

// MARK: - Shared execution core

/// The result of a single URLSession round-trip through `execute`.
internal enum ExecuteResult {
  /// A 2xx response with body, status code, and optional `Link` header.
  case success(Data, statusCode: Int, linkHeader: String?)
  /// No GitHub token was available.
  case noToken
  /// A non-2xx HTTP status code was returned.
  case httpError(Int)
  /// The request was rate limited (403/429 with rate-limit signals).
  case rateLimited
  /// The request was denied (403/429 without rate-limit signals).
  case permissionDenied
  /// A transport-level network error occurred.
  case networkError(Error)
}
