// JobNameSanitisation.swift
// RunBotCore
import Foundation

// MARK: - Job name sanitisation for ZIP lookup

/// Sanitises a GitHub job name for use as a ZIP folder prefix.
///
/// Applies three rules in order, matching the logic in `getJobNameForLogFilename` in the
/// `gh` CLI ([`logs.go`](https://github.com/cli/cli/blob/trunk/pkg/cmd/run/view/logs.go))
/// and the C# server's `GetJobNameForLogFilename`:
/// 1. Strip characters invalid in Windows file paths — the C# server (which writes the ZIP)
///    strips `/`, `:`, `"`, `*`, `?`, `<`, `>`, `|`. Not stripping these causes a prefix
///    mismatch when a job name contains any of them and the server has already removed them
///    from the ZIP folder name.
/// 2. Truncate to **90 UTF-16 code units** — the GitHub server (C#) truncates using
///    `String.Substring(0, 90)` which counts UTF-16 `Char` objects. Swift `.count` counts
///    Unicode scalars, not UTF-16 code units — emoji and CJK characters truncate at a
///    different offset without this step.
/// 3. Trim leading/trailing whitespace/newlines — the C# server calls `.Trim()` after truncation
///    (and the `gh` CLI does `strings.TrimSpace`). Truncation can expose trailing
///    whitespace that was previously interior.
func sanitizeJobNameForZIP(_ name: String) -> String {
    // Strip the full set of characters the C# server considers invalid in a Windows path.
    // The `gh` CLI only strips `/` and `:` explicitly, but the server strips all of these.
    // Stripping only `/` and `:` causes silent misses when job names contain `"`, `*`, etc.
    let stripped = name
        .replacingOccurrences(of: "/", with: "")
        .replacingOccurrences(of: ":", with: "")
        .replacingOccurrences(of: "\"", with: "")
        .replacingOccurrences(of: "*", with: "")
        .replacingOccurrences(of: "?", with: "")
        .replacingOccurrences(of: "<", with: "")
        .replacingOccurrences(of: ">", with: "")
        .replacingOccurrences(of: "|", with: "")
    guard stripped.utf16.count > 90 else { return stripped.trimmingCharacters(in: .whitespacesAndNewlines) }
    var units = Array(stripped.utf16.prefix(90))
    // Guard against splitting a surrogate pair at the 90-unit boundary.
    // Swift strings are always well-formed, so surrogates only appear as
    // high+low pairs. The only reachable split is a high surrogate at position
    // 89 (0xD800–0xDBFF) whose low partner was at 90 and is now dropped —
    // remove the dangling high to keep the output valid.
    // A lone low surrogate (0xDC00–0xDFFF) at the boundary cannot arise from a
    // well-formed Swift String: the high surrogate at 88 would still be present,
    // keeping the pair intact. Malformed UTF-16 fed via String(decoding:as:UTF16.self)
    // is normalised to U+FFFD before we ever see it, so no guard is needed.
    if let last = units.last, (0xD800...0xDBFF).contains(last) {
        units.removeLast()
    }
    // Mirror the C# server's `.Trim()` call (and the gh CLI's `strings.TrimSpace`) which
    // both trim the result after truncation. Truncation can expose trailing whitespace
    // that was previously interior.
    return String(decoding: units, as: UTF16.self).trimmingCharacters(in: .whitespacesAndNewlines)
}
