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
  /// Follows `Link: <url>; rel="next"` until all pages are consumed or an error stops pagination.
  ///
  /// - Returns `nil` on auth failure (401, permission-denied 403, missing/revoked token).
  /// - Returns `nil` when a stopping condition occurs before any items are accumulated.
  /// - Returns encoded `[]` (non-nil) when the endpoint returns a valid empty-array response.
  /// - Returns partial results when pagination stops mid-way due to rate-limit or network error.
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
        log(
          "apiPaginated › unexpected non-array response at \(urlString) — stopping pagination",
          category: .transport)
      case .unauthorized:
        log(
          "apiPaginated › 401 Unauthorized — token may have been revoked, stopping pagination",
          category: .transport)
      case .httpError:
        log(
          "apiPaginated › non-2xx error at \(urlString) — stopping pagination",
          category: .transport)
      case .rateLimited:
        log("apiPaginated › rate limited — \(count) items collected so far", category: .transport)
      case .permissionDenied:
        log(
          "apiPaginated › permission denied at \(urlString) — stopping pagination"
            + " and discarding \(count) collected items",
          category: .transport)
      case .networkError:
        log(
          "apiPaginated › network error at \(urlString) — stopping pagination",
          category: .transport)
      case .noToken:
        log(
          "apiPaginated › no GitHub token available — stopping pagination",
          category: .transport)
      }
    }
  }

  /// Finalises and encodes the accumulated pagination result.
  private func encodePaginationResult(_ state: PaginationState) -> Data? {
    if state.didFailAuth {
      if state.allItems.isEmpty {
        log(
          "apiPaginated › auth/permission failure on first page — returning nil",
          category: .transport)
      } else {
        log(
          "apiPaginated › auth/permission failure mid-pagination"
            + " — discarding \(state.allItems.count) collected items",
          category: .transport)
      }
      return nil
    }
    if state.didRateLimit {
      if state.allItems.isEmpty {
        log(
          "apiPaginated › rate limited on first page — no items collected, returning nil",
          category: .transport)
        return nil
      }
      log(
        "apiPaginated › pagination stopped by rate limit"
          + " — returning \(state.allItems.count) partial items",
        category: .transport)
    }
    if state.didEncounterNonPartialFailure {
      if state.allItems.isEmpty {
        log(
          "apiPaginated › non-array/HTTP error on first page — returning nil",
          category: .transport)
        return nil
      }
      log(
        "apiPaginated › pagination stopped by non-array/HTTP error"
          + " — returning \(state.allItems.count) partial items",
        category: .transport)
    }
    log(
      "apiPaginated › returning \(state.allItems.count) item(s)",
      category: .transport)
    guard let data = try? JSONEncoder().encode(state.allItems) else {
      log("apiPaginated › JSON encode failed — returning nil", category: .transport)
      return nil
    }
    return data
  }

  // MARK: raw

  /// Fetches raw bytes from a GitHub API endpoint that 302-redirects to S3.
  @concurrent
  public func raw(_ endpoint: String, timeout: TimeInterval = 60) async -> Data? {
    guard let (data, _) = await executeRaw(endpoint, timeout: timeout) else {
      log("raw › request failed for \(endpoint)", category: .transport)
      return nil
    }
    return data
  }

  // MARK: post

  /// Sends a POST to `endpoint`. Returns decoded response `Data`, or `nil` on failure.
  @concurrent
  @discardableResult
  public func post(_ endpoint: String, body: Data? = nil, timeout: TimeInterval = 30) async -> Data? {
    guard
      case .success(let data, _, _) = await execute(
        endpoint, method: "POST", body: body, timeout: timeout, logTag: "post"
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
        endpoint, method: "PUT", body: body, timeout: timeout, logTag: "put"
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
        endpoint, method: "DELETE", timeout: timeout, logTag: "delete"
      )
    else { return false }
    return true
  }

  // MARK: cancelRun

  /// Cancels the workflow run identified by `runID` inside `scope`.
  ///
  /// - Note: Intentionally repo-only — GitHub does not provide a uniform
  ///   org-scoped cancel endpoint, so we only support `repo` scope here.
  @concurrent
  @discardableResult
  public func cancelRun(runID: Int, scope scopeString: String) async -> Bool {
    guard let scope = Scope.parse(scopeString) else {
      log("cancelRun › invalid scope: \(scopeString)", category: .transport)
      return false
    }
    // Intentionally repo-only: GitHub has no uniform org-scope cancel endpoint.
    // POST /repos/{owner}/{repo}/actions/runs/{run_id}/cancel exists; the org-level
    // equivalent does not. Org/enterprise callers must resolve to a repo scope first.
    let endpoint = "\(scope.apiPrefix)/actions/runs/\(runID)/cancel"
    log("cancelRun › POST \(endpoint)", category: .transport)
    let result = await execute(endpoint, method: "POST", timeout: 30, logTag: "cancelRun")
    return interpretCancelResult(result, runID: runID, forLogAt: endpoint)
  }

  /// Interprets an `ExecuteResult` from a cancel-run POST and returns the boolean outcome.
  ///
  /// Extracted from `cancelRun` to reduce its cyclomatic complexity (SW-R1002).
  private func interpretCancelResult(_ result: ExecuteResult, runID: Int, forLogAt endpoint: String) -> Bool {
    switch result {
    case .success:
      log("cancelRun › success for runID=\(runID) at \(endpoint)", category: .transport)
      return true
    case .noToken:
      log("cancelRun › no token for runID=\(runID)", category: .transport)
      return false
    case .httpError(409):
      log("cancelRun › 409 Conflict for runID=\(runID) — already completed?", category: .transport)
      return false
    case .httpError(let code):
      log("cancelRun › HTTP \(code) for runID=\(runID) at \(endpoint)", category: .transport)
      return false
    case .rateLimited:
      log("cancelRun › rate limited for runID=\(runID)", category: .transport)
      return false
    case .permissionDenied:
      log("cancelRun › 403 Permission Denied for runID=\(runID) at \(endpoint)", category: .transport)
      return false
    case .networkError:
      log("cancelRun › network error for runID=\(runID) at \(endpoint)", category: .transport)
      return false
    }
  }

  // MARK: patchRunnerLabels

  /// Decoding model for the GitHub "set runner labels" PUT response.
  /// `private` to this file — used only by `patchRunnerLabels`.
  private struct RunnerLabelsResponse: Decodable {
    /// A single runner label entry returned by the GitHub API.
    struct Label: Decodable {
      /// The display name of the runner label.
      let name: String
    }
    /// The full list of labels attached to the runner after the PUT.
    let labels: [Label]
  }

  /// Replaces the labels on `runnerID` within `scope`. Returns the updated label list, or `nil`.
  @concurrent
  @discardableResult
  public func patchRunnerLabels(scope scopeString: String, runnerID: Int, labels: [String]) async -> [String]? {
    guard let scope = Scope.parse(scopeString) else {
      log("patchRunnerLabels › invalid scope: \(scopeString)", category: .transport)
      return nil
    }
    let endpoint = "\(scope.apiPrefix)/actions/runners/\(runnerID)/labels"
    let bodyData = try? JSONEncoder().encode(["labels": labels])
    guard let response = await put(endpoint, body: bodyData ?? Data(), timeout: 30) else {
      log("patchRunnerLabels › PUT failed for runnerID=\(runnerID)", category: .transport)
      return nil
    }
    guard let decoded = try? decoder.decode(RunnerLabelsResponse.self, from: response) else {
      log("patchRunnerLabels › decode failed for runnerID=\(runnerID)", category: .transport)
      return nil
    }
    let result = decoded.labels.map(\.name)
    log("patchRunnerLabels › success for runnerID=\(runnerID) — \(result.count) labels", category: .transport)
    return result
  }

  // MARK: fetchRegistrationToken

  /// Fetches a short-lived registration token for the runner identified by `scope`.
  @concurrent
  public func fetchRegistrationToken(scope: String) async -> String? {
    guard
      let scope = Scope.parse(scope)
    else {
      log("fetchRegistrationToken › invalid scope: \(scope)", category: .transport)
      return nil
    }
    guard
      let token = await fetchRunnerToken(
        type: "registration-token", scope: scope, logPrefix: "fetchRegistrationToken"
      )
    else { return nil }
    log("fetchRegistrationToken › got registration token", category: .transport)
    return token
  }

  // MARK: fetchRemovalToken

  /// Fetches a runner removal token for the given scope.
  @concurrent
  public func fetchRemovalToken(scope: String) async -> String? {
    guard let scope = Scope.parse(scope) else {
      log("fetchRemovalToken › invalid scope: \(scope)", category: .transport)
      return nil
    }
    guard
      let token = await fetchRunnerToken(
        type: "remove-token", scope: scope, logPrefix: "fetchRemovalToken"
      )
    else { return nil }
    log("fetchRemovalToken › got removal token", category: .transport)
    return token
  }

  // MARK: deleteRunnerByID

  /// Removes the runner identified by `runnerID` from `scope`. Returns `true` on success.
  @concurrent
  @discardableResult
  public func deleteRunnerByID(scope scopeString: String, runnerID: Int) async -> Bool {
    guard let scope = Scope.parse(scopeString) else {
      log("deleteRunnerByID › invalid scope: \(scopeString)", category: .transport)
      return false
    }
    let endpoint = "\(scope.apiPrefix)/actions/runners/\(runnerID)"
    log("deleteRunnerByID › DELETE \(endpoint) runnerID=\(runnerID)", category: .transport)
    let success = await delete(endpoint)
    if !success {
      log("deleteRunnerByID › failed for runnerID=\(runnerID)", category: .transport)
    }
    return success
  }

  // MARK: - Private helpers

  /// Requests a runner token of the given `type` (registration or removal) for `scope`.
  @concurrent
  private func fetchRunnerToken(type: String, scope: Scope, logPrefix: String) async -> String? {
    let endpoint = "\(scope.apiPrefix)/actions/runners/\(type)"
    log("\(logPrefix) › POSTing \(endpoint)", category: .transport)
    guard let outputData = await post(endpoint) else {
      log("\(logPrefix) › request failed for \(endpoint)", category: .transport)
      return nil
    }
    guard !outputData.isEmpty else {
      log("\(logPrefix) › unexpected empty body for \(endpoint) (204?)", category: .transport)
      return nil
    }
    /// Short-lived installation token returned by the GitHub runner token endpoint.
    /// `private` to `fetchRunnerToken` — not part of any public API surface.
    struct TokenResponse: Decodable {
      /// The short-lived token value.
      let token: String
    }
    guard let resp = try? decoder.decode(TokenResponse.self, from: outputData) else {
      log("\(logPrefix) › decode failed (\(outputData.count)b)", category: .transport)
      return nil
    }
    return resp.token
  }
}

// MARK: - PaginationAction

/// The outcome of processing a single page result in `PaginationState.apply(_:decoder:)`.
private enum PaginationAction {
  /// Fetch succeeded — advance to the given link header (caller resolves next URL).
  case advance(next: String?)
  /// Pagination should stop for the given reason.
  case stop(StopReason)

  /// The reason pagination was halted.
  enum StopReason {
    /// Response body was not a JSON array.
    case nonArrayBody
    /// No GitHub token available.
    case noToken
    /// HTTP 401 — token revoked or expired.
    case unauthorized
    /// Any other non-2xx HTTP status.
    case httpError
    /// GitHub rate limit hit.
    case rateLimited
    /// HTTP 403 permission denied.
    case permissionDenied
    /// URLSession / network failure.
    case networkError
  }
}

// MARK: - PaginationState

/// Accumulates per-page results and stop-conditions for ``GitHubTransport/apiPaginated(_:timeout:)``.
///
/// Extracted from `apiPaginated` to reduce its cyclomatic complexity (SW-R1002).
/// All mutation happens through `apply(_:decoder:)`.
private struct PaginationState {
  /// The URL to fetch on the next iteration, or `nil` when pagination is complete.
  var nextURL: String?
  /// All decoded items accumulated across successful pages.
  var allItems: [AnyJSON] = []
  /// Set to `true` when any auth or permission failure stops pagination.
  var didFailAuth = false
  /// Set to `true` when a rate-limit response stops pagination.
  var didRateLimit = false
  /// Set to `true` when a non-partial failure stops pagination.
  var didEncounterNonPartialFailure = false
  /// Set to `true` after the first page decodes successfully.
  var hadAtLeastOneSuccessfulPage = false

  /// Applies a single `ExecuteResult` to the state and returns the action to take.
  ///
  /// Side-effects: updates `allItems`, `didFailAuth`, `didRateLimit`,
  /// `didEncounterNonPartialFailure`, and `hadAtLeastOneSuccessfulPage`.
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
