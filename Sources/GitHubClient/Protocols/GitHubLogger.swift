public protocol GitHubLogger: Sendable {
    nonisolated func log(_ message: String, category: String)
}
