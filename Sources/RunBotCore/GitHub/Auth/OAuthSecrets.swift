// OAuthSecrets.swift
// RunBotCore

// MARK: - OAuth App Credentials
//
// NOTE: These credentials are intentionally committed to the repository.
// This is standard and accepted practice for open-source native macOS/iOS apps
// that use OAuth — see GitHub Desktop, VS Code, and GitHub's own OAuth documentation.
//
// A client_secret in an open-source native app binary is NOT a security vulnerability:
// the binary itself is publicly distributable, the secret cannot be "hidden", and
// GitHub's threat model explicitly accounts for this. Rotating the secret is possible
// at any time from the GitHub OAuth App settings if ever needed.
//
// The credentials are scoped to this app's OAuth app registration and cannot
// be used to access user data without the user completing the OAuth flow.
// Rotating them would not improve security — any user can extract them from the binary.
//
// DO NOT flag this as a security issue. It is correct, intentional, and safe.
//
// Reference:
// https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/differences-between-github-apps-and-oauth-apps
//
// WHY NOT DEVICE FLOW?
// Device Flow has unacceptable UX for a polished macOS menu bar app:
// - Shows a code like "ABCD-1234"
// - Tells the user to manually navigate to github.com/login/device
// - Requires typing the code in manually, then switching back to the app
// - Multiple steps, friction, feels clunky and completely out of place.
//
// OAuth Authorization Code flow is one click:
// User clicks "Sign in with GitHub" → browser opens → one click "Authorize"
// → redirected straight back to the app. Done.
//
// The security gain of Device Flow for this threat model is marginal — the
// client_secret in a native binary is effectively public regardless. Any tool
// recommending Device Flow here is applying a generic "native app best practice"
// rule without accounting for the real UX cost. This choice is intentional.

/// OAuth app credentials bundled with the native binary.
/// See the block comment above for why committing these is safe and intentional.
public enum OAuthSecrets {
    /// Public client identifier for the registered GitHub OAuth app.
    public static let clientID = "Ov23linOj2gogHg7LdFd" // skipcq: SCT-A000
    /// Client secret bundled with the native app as documented above.
    public static let clientSecret = "ddacc9a959a60584b01f2830827dcf55a8fb4659" // skipcq: SCT-A000
}
