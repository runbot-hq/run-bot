// Exports.swift
// GitHubClient
//
// Re-exports peer kit targets so consumers only need `import GitHubClient`.
// Without @_exported, `public import` (used per-file for compiler access-level
// reasons) does NOT make kit symbols visible to downstream modules.
//
// This preserves the single-import contract: RunBot and other clients
// import only GitHubClient and get OAuthTokenKit + EnvTokenKit symbols
// transitively.

@_exported import OAuthTokenKit
@_exported import EnvTokenKit
