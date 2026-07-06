// RunnerProxyStoreError.swift
// RunBotCore
import Foundation

// MARK: - RunnerProxyStoreError

/// Errors thrown while writing proxy configuration files.
public enum RunnerProxyStoreError: LocalizedError {
    /// One or more proxy files could not be written or removed.
    /// `messages` contains a human-readable description for each failing file.
    case writeFailed([String])

    /// A human-readable description of the error, suitable for display in alerts.
    public var errorDescription: String? {
        switch self {
        case .writeFailed(let messages):
            "Failed to write proxy files: " + messages.joined(separator: "; ")
        }
    }
}
