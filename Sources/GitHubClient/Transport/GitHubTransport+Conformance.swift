// GitHubTransport+Conformance.swift
// GitHubClient

import Foundation

// MARK: - GitHubTransport: protocol conformance

/// Conformance to ``GitHubTransportProtocol`` — all public API surface.
extension GitHubTransport {

  // MARK: apiAsync

  /// Fetches a single GitHub API page. Returns decoded `Data` on success, `nil` on any failure.
  @concurrent
  public func apiAsync(_ endpoint: String, timeout: TimeInterval = 20) async -> Data? {
    guard
      case .success(let data, _, _) = await execute(
        endpoint, timeout: timeout, logTag: "apiAsync"
      )
    else { return nil }
    return data
  }

  // MARK: apiPaginated

  /// Fetches and concatenates all pages for a GitHub paginated endpoint.
  @concurrent
  public func apiPaginated(_ endpoint: String, timeout: TimeInterval = 60) async -> Data? {
    var state = PaginationState(nextURL: resolveURL(endpoint))
    while let urlString = state.nextURL {
      let result = await execute(urlString, timeout: timeout, logTag: "apiPaginated")
      let action = state.apply(result, decoder: decoder)
      applyPaginationLog(action, urlString: urlString, count: state.allItems.count)
      if case .advance(let linkHeader) = action {
        state.nextURL = extractNextURL(from: linkHeader)
      } else {
        break
      }
    }
    return encodePaginationResult(state)
  }

  /// Logs the outcome of a single pagination step.
  private func applyPaginationLog(_ action: PaginationAction, urlString: String, count: Int) {
    switch action {
    case .advance:
      break
    case .stop(let reason):
      switch reason {
      case .nonArrayBody:
        logger?.log(
          "apiPaginated › unexpected non-array response at \(urlString) — stopping pagination",
          category: "transport")
      case .unauthorized:
        logger?.log(
          "apiPaginated › 401 Unauthorized — token may have been revoked, stopping pagination",
          category: "transport")
      case .httpError:
        logger?.log(
          "apiPaginated › non-2xx error at \(urlString) — stopping pagination",
          category: "transport")
      case .rateLimited:
        logger?.log("apiPaginated › rate limited — \(count) items collected so far", category: "transport")
      case .permissionDenied:
        logger?.log(
          "apiPaginated › permission denied at \(urlString) — stopping pagination"
            + " and discarding \(count) collected items",
          category: "transport")
      case .networkError:
        logger?.log(
          "apiPaginated › network error at \(urlString) — stopping pagination",
          category: "transport")
      case .noToken:
        logger?.log(
          "apiPaginated › no GitHub token available — stopping pagination",
          category: "transport")
      }
    }
  }

  /// Finalises and encodes the accumulated pagination result.
  private func encodePaginationResult(_ state: PaginationState) -> Data? {
    if state.didFailAuth {
      if state.allItems.isEmpty {
        logger?.log(
          "apiPaginated › auth/permission failure on first page — returning nil",
          category: "transport")
      } else {
        logger?.log(
          "apiPaginated › auth/permission failure mid-pagination"
            + " — discarding \(state.allItems.count) collected items",
          category: "transport")
      }
      return nil
    }
    if state.didRateLimit {
      if state.allItems.isEmpty {
        logger?.log(
          "apiPaginated › rate limited on first page — no items collected, returning nil",
          category: "transport")
        return nil
      }
      logger?.log(
        "apiPaginated › pagination stopped by rate limit"
          + " — returning \(state.allItems.count) partial items",
        category: "transport")
    }
    if state.didEncounterNonPartialFailure {
      if state.allItems.isEmpty {
        logger?.log(
          "apiPaginated › non-array/HTTP error on first page — returning nil",
          category: "transport")
        return nil
      }
      logger?.log(
        "apiPaginated › pagination stopped by non-array/HTTP error"
          + " — returning \(state.allItems.count) partial items",
        category: "transport")
    }
    guard state.hadAtLeastOneSuccessfulPage else {
      logger?.log(
        "apiPaginated › loop ended without any successful page — returning nil",
        category: "transport")
      return nil
    }
    logger?.log(
      "apiPaginated › returning \(state.allItems.count) item(s)",
      category: "transport")
    guard let data = try? JSONEncoder().encode(state.allItems) else {
      logger?.log("apiPaginated › JSON encode failed — returning nil", category: "transport")
      return nil
    }
    return data
  }

  // MARK: raw

  /// Fetches raw bytes from a GitHub API endpoint that 302-redirects to S3.
  @concurrent
  public func raw(_ endpoint: String, timeout: TimeInterval = 60) async -> Data? {
    guard
      case .success(let data, _, _) = await execute(
        endpoint, timeout: timeout, logTag: "raw", useRawAccept: true
      )
    else {
      logger?.log("raw › request failed for \(endpoint)", category: "transport")
      return nil
    }
    logger?.log("raw › \(endpoint) → \(data.count)b", category: "transport")
    return data
  }

  // MARK: post

  /// Sends a POST to `endpoint`. Returns decoded response `Data`, or `nil` on failure.
  @concurrent
  @discardableResult
  public func post(_ endpoint: String, body: Data? = nil, timeout: TimeInterval = 30) async -> Data? {
    guard
      case .success(let data, _, _) = await execute(
        endpoint,
        timeout: timeout,
        logTag: "post",
        configure: { req in
          var request = req
          request.httpMethod = "POST"
          if let body { request.httpBody = body }
          return request
        }
      )
    else { return nil }
    return data
  }

  // MARK: put

  /// Sends a PUT with `body` to `endpoint`. Returns decoded response `Data`, or `nil` on failure.
  @concurrent
  public func put(_ endpoint: String, body: Data, timeout: TimeInterval = 30) async -> Data? {
    guard
      case .success(let data, _, _) = await execute(
        endpoint,
        timeout: timeout,
        logTag: "put",
        configure: { req in
          var request = req
          request.httpMethod = "PUT"
          request.httpBody = body
          return request
        }
      )
    else { return nil }
    return data
  }

  // MARK: delete

  /// Sends a DELETE to `endpoint`. Returns `true` on 2xx, `false` otherwise.
  @concurrent
  @discardableResult
  public func delete(_ endpoint: String, timeout: TimeInterval = 30) async -> Bool {
    guard
      case .success = await execute(
        endpoint,
        timeout: timeout,
        logTag: "delete",
        configure: { req in
          var request = req
          request.httpMethod = "DELETE"
          return request
        }
      )
    else { return false }
    return true
  }

  // MARK: cancelRun

  /// Cancels the workflow run identified by `runID` inside `scope`.
  @concurrent
  @discardableResult
  public func cancelRun(runID: Int, scope scopeString: String) async -> Bool {
    guard let scope = Scope.parse(scopeString) else {
      logger?.log("cancelRun › invalid scope: \(scopeString)", category: "transport")
      return false
    }
    let endpoint = "\(scope.apiPrefix)/actions/runs/\(runID)/cancel"
    logger?.log("cancelRun › POST \(endpoint)", category: "transport")
    let result = await execute(
      endpoint,
      timeout: 30,
      logTag: "cancelRun",
      configure: { req in var request = req; request.httpMethod = "POST"; return request }
    )
    return interpretCancelResult(result, runID: runID, forLogAt: endpoint)
  }

  /// Interprets an `ExecuteResult` from a cancel-run POST and returns the boolean outcome.
  private func interpretCancelResult(_ result: ExecuteResult, runID: Int, forLogAt endpoint: String) -> Bool {
    switch result {
    case .success:
      logger?.log("cancelRun › success for runID=\(runID) at \(endpoint)", category: "transport")
      return true
    case .noToken:
      logger?.log("cancelRun › no token for runID=\(runID)", category: "transport")
      return false
    case .httpError(409):
      logger?.log("cancelRun › 409 Conflict for runID=\(runID) — already completed?", category: "transport")
      return false
    case .httpError(let code):
      logger?.log("cancelRun › HTTP \(code) for runID=\(runID) at \(endpoint)", category: "transport")
      return false
    case .rateLimited:
      logger?.log("cancelRun › rate limited for runID=\(runID)", category: "transport")
      return false
    case .permissionDenied:
      logger?.log("cancelRun › 403 Permission Denied for runID=\(runID) at \(endpoint)", category: "transport")
      return false
    case .networkError:
      logger?.log("cancelRun › network error for runID=\(runID) at \(endpoint)", category: "transport")
      return false
    }
  }

  // MARK: patchRunnerLabels

  /// Decodes the `labels` array returned by the runner-labels endpoint.
  private struct RunnerLabelsResponse: Decodable {
    /// A single runner label entry.
    struct Label: Decodable {
      /// The label's display name.
      let name: String
    }
    /// The runner's current labels.
    let labels: [Label]
  }

  /// Replaces the labels on `runnerID` within `scope`. Returns the updated label list, or `nil`.
  @concurrent
  @discardableResult
  public func patchRunnerLabels(scope scopeString: String, runnerID: Int, labels: [String]) async -> [String]? {
    guard let scope = Scope.parse(scopeString) else {
      logger?.log("patchRunnerLabels › invalid scope: \(scopeString)", category: "transport")
      return nil
    }
    let endpoint = "\(scope.apiPrefix)/actions/runners/\(runnerID)/labels"
    let bodyData = try? JSONEncoder().encode(["labels": labels])
    guard let response = await put(endpoint, body: bodyData ?? Data(), timeout: 30) else {
      logger?.log("patchRunnerLabels › PUT failed for runnerID=\(runnerID)", category: "transport")
      return nil
    }
    guard let decoded = try? decoder.decode(RunnerLabelsResponse.self, from: response) else {
      logger?.log("patchRunnerLabels › decode failed for runnerID=\(runnerID)", category: "transport")
      return nil
    }
    let result = decoded.labels.map(\.name)
    logger?.log("patchRunnerLabels › success for runnerID=\(runnerID) — \(result.count) labels", category: "transport")
    return result
  }

  // MARK: fetchRegistrationToken

  /// Fetches a short-lived registration token for the runner identified by `scope`.
  @concurrent
  public func fetchRegistrationToken(scope: String) async -> String? {
    guard let scope = Scope.parse(scope) else {
      logger?.log("fetchRegistrationToken › invalid scope: \(scope)", category: "transport")
      return nil
    }
    guard
      let token = await fetchRunnerToken(
        type: "registration-token", scope: scope, logPrefix: "fetchRegistrationToken"
      )
    else { return nil }
    logger?.log("fetchRegistrationToken › got registration token", category: "transport")
    return token
  }

  // MARK: fetchRemovalToken

  /// Fetches a runner removal token for the given scope.
  @concurrent
  public func fetchRemovalToken(scope: String) async -> String? {
    guard let scope = Scope.parse(scope) else {
      logger?.log("fetchRemovalToken › invalid scope: \(scope)", category: "transport")
      return nil
    }
    guard
      let token = await fetchRunnerToken(
        type: "remove-token", scope: scope, logPrefix: "fetchRemovalToken"
      )
    else { return nil }
    logger?.log("fetchRemovalToken › got removal token", category: "transport")
    return token
  }

  // MARK: deleteRunnerByID

  /// Removes the runner identified by `runnerID` from `scope`. Returns `true` on success.
  @concurrent
  @discardableResult
  public func deleteRunnerByID(scope scopeString: String, runnerID: Int) async -> Bool {
    guard let scope = Scope.parse(scopeString) else {
      logger?.log("deleteRunnerByID › invalid scope: \(scopeString)", category: "transport")
      return false
    }
    let endpoint = "\(scope.apiPrefix)/actions/runners/\(runnerID)"
    logger?.log("deleteRunnerByID › DELETE \(endpoint) runnerID=\(runnerID)", category: "transport")
    let success = await delete(endpoint)
    if !success {
      logger?.log("deleteRunnerByID › failed for runnerID=\(runnerID)", category: "transport")
    }
    return success
  }

  // MARK: - Private helpers

  /// Requests a runner token of the given `type` (registration or removal) for `scope`.
  @concurrent
  private func fetchRunnerToken(type: String, scope: Scope, logPrefix: String) async -> String? {
    let endpoint = "\(scope.apiPrefix)/actions/runners/\(type)"
    logger?.log("\(logPrefix) › POSTing \(endpoint)", category: "transport")
    guard let outputData = await post(endpoint) else {
      logger?.log("\(logPrefix) › request failed for \(endpoint)", category: "transport")
      return nil
    }
    guard !outputData.isEmpty else {
      logger?.log("\(logPrefix) › unexpected empty body for \(endpoint) (204?)", category: "transport")
      return nil
    }
    struct TokenResponse: Decodable {
      let token: String
    }
    guard let resp = try? decoder.decode(TokenResponse.self, from: outputData) else {
      logger?.log("\(logPrefix) › decode failed (\(outputData.count)b)", category: "transport")
      return nil
    }
    return resp.token
  }
}

// MARK: - PaginationAction

/// The outcome of applying one paginated response to the accumulating state.
private enum PaginationAction {
  /// Continue paginating; the associated value carries the raw `Link` header.
  case advance(next: String?)
  /// Stop paginating for the given reason.
  case stop(StopReason)

  /// Why pagination stopped.
  enum StopReason {
    /// The response body was not the expected JSON array.
    case nonArrayBody
    /// No GitHub token was available.
    case noToken
    /// The server returned 401 Unauthorized.
    case unauthorized
    /// The server returned a non-2xx status.
    case httpError
    /// The request was rate limited.
    case rateLimited
    /// The server returned 403 Permission Denied.
    case permissionDenied
    /// A transport-level network error occurred.
    case networkError
  }
}

// MARK: - PaginationState

/// Mutable accumulator threaded through the pagination loop.
private struct PaginationState {
  /// The URL of the next page to fetch, or `nil` when pagination is complete.
  var nextURL: String?
  /// All items collected across pages so far.
  var allItems: [AnyJSON] = []
  /// Whether an auth/permission failure was encountered.
  var didFailAuth = false
  /// Whether the request was rate limited.
  var didRateLimit = false
  /// Whether a non-partial (non-array/HTTP) failure was encountered.
  var didEncounterNonPartialFailure = false
  /// Whether at least one page decoded successfully.
  var hadAtLeastOneSuccessfulPage = false

  /// Applies one `ExecuteResult` to the state and returns the next pagination action.
  mutating func apply(
    _ result: ExecuteResult,
    decoder: JSONDecoder
  ) -> PaginationAction {
    switch result {
    case .success(let data, _, let linkHeader):
      guard let page = try? decoder.decode([AnyJSON].self, from: data) else {
        didEncounterNonPartialFailure = true
        return .stop(.nonArrayBody)
      }
      hadAtLeastOneSuccessfulPage = true
      allItems.append(contentsOf: page)
      return .advance(next: linkHeader)
    case .noToken:
      didFailAuth = true
      return .stop(.noToken)
    case .httpError(401):
      didFailAuth = true
      return .stop(.unauthorized)
    case .httpError:
      didEncounterNonPartialFailure = true
      return .stop(.httpError)
    case .rateLimited:
      didRateLimit = true
      return .stop(.rateLimited)
    case .permissionDenied:
      didFailAuth = true
      return .stop(.permissionDenied)
    case .networkError:
      return .stop(.networkError)
    }
  }
}
