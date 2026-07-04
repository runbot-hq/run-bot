// GitHubTransportShims.swift
// GitHubClient

import Foundation

// MARK: - Shared default instance

/// The process-wide default `GitHubTransport` instance.
public let sharedGitHubTransport = GitHubTransport()

// MARK: - Backward-compatibility shims

@concurrent
public func urlSessionAPIAsync(_ endpoint: String, timeout: TimeInterval = 20) async -> Data? {
    await sharedGitHubTransport.apiAsync(endpoint, timeout: timeout)
}

@concurrent
public func urlSessionAPIPaginated(
    _ endpoint: String,
    timeout: TimeInterval = 60
) async -> Data? {
    await sharedGitHubTransport.apiPaginated(endpoint, timeout: timeout)
}

@concurrent
public func urlSessionRaw(_ endpoint: String, timeout: TimeInterval = 60) async -> Data? {
    await sharedGitHubTransport.raw(endpoint, timeout: timeout)
}

@concurrent
@discardableResult
public func urlSessionPost(_ endpoint: String, body: Data? = nil, timeout: TimeInterval = 30) async -> Data? {
    await sharedGitHubTransport.post(endpoint, body: body, timeout: timeout)
}

@concurrent
public func urlSessionPut(_ endpoint: String, body: Data, timeout: TimeInterval = 30) async -> Data? {
    await sharedGitHubTransport.put(endpoint, body: body, timeout: timeout)
}

@concurrent
@discardableResult
public func urlSessionDelete(_ endpoint: String, timeout: TimeInterval = 30) async -> Bool {
    await sharedGitHubTransport.delete(endpoint, timeout: timeout)
}

@concurrent
public func ghAPI(_ endpoint: String, timeout: TimeInterval = 20) async -> Data? {
    await sharedGitHubTransport.apiAsync(endpoint, timeout: timeout)
}

@concurrent
@discardableResult
public func ghPost(_ endpoint: String) async -> Bool {
    let result = await sharedGitHubTransport.post(endpoint)
    let success = result != nil
    log("ghPost › \(endpoint) success=\(success)", category: .transport)
    return success
}

@concurrent
@discardableResult
public func deleteRunnerByID(scope scopeString: String, runnerID: Int) async -> Bool {
    await sharedGitHubTransport.deleteRunnerByID(scope: scopeString, runnerID: runnerID)
}

@concurrent
@discardableResult
public func patchRunnerLabels(scope scopeString: String, runnerID: Int, labels: [String]) async -> [String]? {
    await sharedGitHubTransport.patchRunnerLabels(scope: scopeString, runnerID: runnerID, labels: labels)
}

@concurrent
public func fetchRegistrationToken(scope scopeString: String) async -> String? {
    await sharedGitHubTransport.fetchRegistrationToken(scope: scopeString)
}

@concurrent
public func fetchRemovalToken(scope scopeString: String) async -> String? {
    await sharedGitHubTransport.fetchRemovalToken(scope: scopeString)
}

@concurrent
@discardableResult
public func cancelRun(runID: Int, scope scopeString: String) async -> Bool {
    await sharedGitHubTransport.cancelRun(runID: runID, scope: scopeString)
}
