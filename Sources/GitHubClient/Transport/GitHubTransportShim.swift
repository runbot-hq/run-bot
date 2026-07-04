// GitHubTransportShim.swift
// GitHubClient

import Foundation
import os

// MARK: - Transport types

public typealias GHAPITransport = @Sendable (_ endpoint: String) async -> Data?
public typealias GHRawTransport = @Sendable (_ endpoint: String) async -> Data?
public typealias GHAPIPaginatedTransport = @Sendable (_ endpoint: String, _ timeout: TimeInterval) async -> Data?
public typealias GHTokenProvider = @Sendable () -> String?

// MARK: - TransportBox

private struct TransportBox<T: Sendable> {
    private let lock: OSAllocatedUnfairLock<T>
    init(initialState: T) { lock = .init(initialState: initialState) }
    func configure(_ value: T) { lock.withLock { $0 = value } }
    func read() -> T { lock.withLock { $0 } }
}

// MARK: - Module-level state

private let transportBox = TransportBox<GHAPITransport>(initialState: { _ in nil })
private let rawTransportBox = TransportBox<GHRawTransport>(initialState: { _ in nil })
private let paginatedTransportBox = TransportBox<GHAPIPaginatedTransport>(initialState: { _, _ in nil })
private let tokenProviderBox = TransportBox<GHTokenProvider>(initialState: { nil })

// MARK: - Configuration

public func configureGHAPI(_ transport: @escaping GHAPITransport) {
    transportBox.configure(transport)
}

public func configureGHRaw(_ rawTransport: @escaping GHRawTransport) {
    rawTransportBox.configure(rawTransport)
}

public func configureGHAPIPaginated(_ transport: @escaping GHAPIPaginatedTransport) {
    paginatedTransportBox.configure(transport)
}

public func configureGHToken(_ provider: @escaping GHTokenProvider) {
    tokenProviderBox.configure(provider)
}

// MARK: - Module-level symbols

func ghAPI(_ endpoint: String) async -> Data? {
    let transport = transportBox.read()
    let result = await transport(endpoint)
    if result != nil { await apiCallCounter.record() }
    return result
}

func ghRaw(_ endpoint: String) async -> Data? {
    let transport = rawTransportBox.read()
    return await transport(endpoint)
}

@concurrent
public func ghAPIPaginated(_ endpoint: String, timeout: TimeInterval = 60) async -> Data? {
    let transport = paginatedTransportBox.read()
    let result = await transport(endpoint, timeout)
    if result != nil { await apiCallCounter.record() }
    return result
}

func githubTokenCore() -> String? {
    let provider = tokenProviderBox.read()
    return provider()
}
