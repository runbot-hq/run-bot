// GitHubTransport+Conformance.swift
// GitHubClient

import Foundation

// MARK: - GitHubTransport: protocol conformance

extension GitHubTransport {

  // MARK: apiAsync

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
      if !state.hadAtLeastOneSuccessfulPage {
        log(
          "apiPaginated › pagination stopped by non-recoverable failure on first page"
            + " — returning nil",
          category: .transport)
        return nil
      }
      log(
        "apiPaginated › pagination stopped by non-recoverable failure mid-pagination"
          + " — returning \(state.allItems.count) partial items",
        category: .transport)
    }
    guard state.hadAtLeastOneSuccessfulPage else {
      log(
        "apiPaginated › loop ended without any successful page — returning nil",
        category: .transport)
      return nil
    }
    do {
      let encoded = try encoder.encode(state.allItems)
      log(
        "apiPaginated › returning \(state.allItems.count) items (\(encoded.count)b)",
        category: .transport)
      return encoded
    } catch {
      log("apiPaginated › encode failed: \(error) — returning nil", category: .transport)
      return nil
    }
  }

  // MARK: raw

  @concurrent
  public func raw(_ endpoint: String, timeout: TimeInterval = 60) async -> Data? {
    guard
      case .success(let data, _, _) = await execute(
        endpoint, timeout: timeout, logTag: "raw", useRawAccept: true
      )
    else { return nil }
    log("raw › \(endpoint) → \(data.count)b", category: .transport)
    return data
  }

  // MARK: post

  @concurrent
  @discardableResult
  public func post(_ endpoint: String, body: Data? = nil, timeout: TimeInterval = 30) async -> Data? {
    let result = await execute(endpoint, timeout: timeout, logTag: "post") { req in
      var request = req
      request.httpMethod = "POST"
      if let body {
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      }
      return request
    }
    guard case .success(let data, let statusCode, _) = result else { return nil }
    log("post › \(endpoint) → \(statusCode)", category: .transport)
    return data
  }

  // MARK: put

  @concurrent
  public func put(_ endpoint: String, body: Data, timeout: TimeInterval = 30) async -> Data? {
    let result = await execute(endpoint, timeout: timeout, logTag: "put") { req in
      var request = req
      request.httpMethod = "PUT"
      request.httpBody = body
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      return request
    }
    guard case .success(let data, let statusCode, _) = result else { return nil }
    log("put › \(endpoint) → \(statusCode)", category: .transport)
    return data
  }

  // MARK: delete

  @concurrent
  @discardableResult
  public func delete(_ endpoint: String, timeout: TimeInterval = 30) async -> Bool {
    let result = await execute(endpoint, timeout: timeout, logTag: "delete") { req in
      var request = req
      request.httpMethod = "DELETE"
      return request
    }
    if case .success = result {
      log("delete › \(endpoint) → success", category: .transport)
      return true
    }
    return false
  }

  // MARK: cancelRun

  @concurrent
  @discardableResult
  public func cancelRun(runID: Int, scope scopeString: String) async -> Bool {
    guard let scope = Scope.parse(scopeString) else {
      log("cancelRun › invalid scope: \(scopeString)", category: .transport)
      return false
    }
    guard case .repo = scope else {
      log(
        "cancelRun › scope must be a repo (owner/name), got: \(scopeString)",
        category: .transport)
      return false
    }
    let endpoint = "\(scope.apiPrefix)/actions/runs/\(runID)/cancel"
    let executeResult = await execute(endpoint, timeout: 30, logTag: "cancelRun") { req in
      var request = req
      request.httpMethod = "POST"
      return request
    }
    return cancelRunResult(executeResult, runID: runID, scopeString: scopeString)
  }

  private func cancelRunResult(
    _ result: ExecuteResult,
    runID: Int,
    scopeString: String
  ) -> Bool {
    switch result {
    case .success:
      log("cancelRun › run=\(runID) scope=\(scopeString) success=true", category: .transport)
      return true
    case .httpError(let code):
      log(
        "cancelRun › run=\(runID) scope=\(scopeString) failed — HTTP \(code)",
        category: .transport)
      return false
    case .noToken:
      log(
        "cancelRun › run=\(runID) scope=\(scopeString) failed — no token",
        category: .transport)
      return false
    case .rateLimited:
      log(
        "cancelRun › run=\(runID) scope=\(scopeString) failed — rate limited",
        category: .transport)
      return false
    case .permissionDenied:
      log(
        "cancelRun › run=\(runID) scope=\(scopeString) failed — permission denied",
        category: .transport)
      return false
    case .networkError(let error):
      log(
        "cancelRun › run=\(runID) scope=\(scopeString) failed — network error:"
          + " \(error.localizedDescription)",
        category: .transport)
      return false
    }
  }

  // MARK: patchRunnerLabels

  private struct LabelsResponse: Decodable {
    struct Label: Decodable {
      let name: String
    }
    let labels: [Label]
  }

  @concurrent
  @discardableResult
  public func patchRunnerLabels(scope scopeString: String, runnerID: Int, labels: [String]) async -> [String]? {
    guard let scope = Scope.parse(scopeString) else {
      log("patchRunnerLabels › invalid scope: \(scopeString)", category: .transport)
      return nil
    }
    let endpoint = "\(scope.apiPrefix)/actions/runners/\(runnerID)/labels"
    log("patchRunnerLabels › PUT \(endpoint) labels=\(labels)", category: .transport)
    guard let bodyData = try? encoder.encode(["labels": labels]) else {
      log("patchRunnerLabels › failed to serialise request body", category: .transport)
      return nil
    }
    guard let outData = await put(endpoint, body: bodyData) else {
      log("patchRunnerLabels › request failed for endpoint=\(endpoint)", category: .transport)
      return nil
    }
    guard let resp = try? decoder.decode(LabelsResponse.self, from: outData) else {
      let raw = String(data: outData, encoding: .utf8) ?? ""
      log("patchRunnerLabels › decode failed raw=\(raw.prefix(200))", category: .transport)
      return nil
    }
    let names = resp.labels.map(\.name)
    log("patchRunnerLabels › success labels=\(names)", category: .transport)
    return names
  }

  // MARK: fetchRegistrationToken / fetchRemovalToken

  @concurrent
  public func fetchRegistrationToken(scope scopeString: String) async -> String? {
    guard let scope = Scope.parse(scopeString) else {
      log("fetchRegistrationToken › invalid scope: \(scopeString)", category: .transport)
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

  @concurrent
  public func fetchRemovalToken(scope scopeString: String) async -> String? {
    guard let scope = Scope.parse(scopeString) else {
      log("fetchRemovalToken › invalid scope: \(scopeString)", category: .transport)
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
    struct TokenResponse: Decodable {
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

private enum PaginationAction {
  case advance(next: String?)
  case stop(StopReason)

  enum StopReason {
    case nonArrayBody
    case noToken
    case unauthorized
    case httpError
    case rateLimited
    case permissionDenied
    case networkError
  }
}

// MARK: - PaginationState

private struct PaginationState {
  var nextURL: String?
  var allItems: [AnyJSON] = []
  var didFailAuth = false
  var didRateLimit = false
  var didEncounterNonPartialFailure = false
  var hadAtLeastOneSuccessfulPage = false

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
