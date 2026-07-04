// OAuthServiceProtocol.swift
// GitHubClient
import Foundation

@MainActor
public protocol OAuthServiceProtocol: AnyObject {
    func makeSignInURL() -> URL?
    func signOut()
    func handleCallback(_ url: URL)
    func makeSignInStream() -> AsyncStream<Bool>
    func makeSignOutStream() -> AsyncStream<Void>
}
