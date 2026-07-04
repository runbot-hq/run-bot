// GitHubURLSessionTransport.swift
// GitHubClient

import Foundation

// MARK: - GitHubTransport

/// The concrete `URLSession`-backed implementation of `GitHubTransportProtocol`.
public struct GitHubTransport: GitHubTransportProtocol {

  // MARK: - Stored properties

  internal let decoder: JSONDecoder
  internal let encoder: JSONEncoder
  private let session: URLSession
  private let rateLimiter: any RateLimitActorProtocol
  private let tokenProvider: @Sendable () -> String?

  // MARK: - Init

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
        statusCode: http.statusCode, data, response: http,
        endpoint: urlString, rateLimiter: rateLimiter
      )
      return wasRateLimited ? .rateLimited : .permissionDenied
    }
    guard (200..<300).contains(http.statusCode) else {
      logErrorBody(data, endpoint: urlString, status: http.statusCode)
      return .httpError(http.statusCode)
    }
    await rateLimiter.clearIfNotLimited()
    let linkHeader = http.value(forHTTPHeaderField: "Link")
    return .success(data, statusCode: http.statusCode, linkHeader: linkHeader)
  }
}

// MARK: - Shared execution core

internal enum ExecuteResult {
  case success(Data, statusCode: Int, linkHeader: String?)
  case noToken
  case httpError(Int)
  case rateLimited
  case permissionDenied
  case networkError(Error)
}
