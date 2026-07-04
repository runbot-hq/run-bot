public protocol TokenStore: Sendable {
    nonisolated func load() -> String?
    nonisolated func save(_ token: String) -> Bool
    nonisolated func delete() -> Bool
}
