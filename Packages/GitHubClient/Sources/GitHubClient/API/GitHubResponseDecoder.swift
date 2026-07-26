// GitHubResponseDecoder.swift
// GitHubClient
import Foundation

// MARK: - Error logging

/// Logs the response body (up to 400 chars) for non-2xx responses.
func logErrorBody(_ data: Data?, endpoint: String, status: Int, logger: (any GitHubLogger)?) {
    guard let data, !data.isEmpty else { return }
    let body = String(data: data, encoding: .utf8) ?? ""
    let preview = body.count > 400 ? String(body.prefix(400)) + "…" : body
    logger?.log("HTTP \(status) \(endpoint): \(preview)", category: "transport")
}

// MARK: - Rate-limit response handler

/// Handles a 403 or 429 rate-limit response by forwarding to the given `RateLimitActorProtocol`.
func handleRateLimitResponse(
    statusCode: Int,
    data: Data?,
    response: HTTPURLResponse,
    endpoint: String,
    rateLimiter: some RateLimitActorProtocol,
    logger: (any GitHubLogger)?
) async -> Bool {
    let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
    let remaining = response.value(forHTTPHeaderField: "X-RateLimit-Remaining").flatMap(Int.init)
    let resetHeader = response.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(TimeInterval.init)
    let isRealRateLimit = statusCode == 429 || remaining == 0 || retryAfter != nil
    guard isRealRateLimit else {
        logger?.log("RateLimit › 403 permission error (not rate limit) — \(endpoint)", category: "transport")
        return false
    }
    let limitKind = rateLimitKind(retryAfter: retryAfter, statusCode: statusCode)
    logErrorBody(data, endpoint: endpoint, status: statusCode, logger: logger)
    let resetAt = resetTimestamp(retryAfter: retryAfter, resetHeader: resetHeader)
    logger?.log(
        "RateLimit › ⚠️ rate limited (\(limitKind)) — \(endpoint) "
        + "status=\(statusCode) "
        + "retryAfter=\(String(describing: retryAfter)) "
        + "resetAt=\(String(describing: resetAt))",
        category: "transport"
    )
    await rateLimiter.set(resetAt: resetAt)
    return true
}

/// Returns `"secondary"` for 429s or `Retry-After`; `"primary"` for quota-exhausted 403s.
private func rateLimitKind(retryAfter: Double?, statusCode: Int) -> String {
    retryAfter != nil || statusCode == 429 ? "secondary" : "primary"
}

/// Computes the absolute reset timestamp from rate-limit response headers.
private func resetTimestamp(retryAfter: Double?, resetHeader: TimeInterval?) -> TimeInterval? {
    if let retryAfter { return Date().timeIntervalSince1970 + retryAfter }
    return resetHeader
}

// MARK: - Pagination

/// Parses the `Link` header from a GitHub paginated response and returns the `next` URL, if any.
func extractNextURL(from header: String?) -> String? {
    guard let header else { return nil }
    for part in header.components(separatedBy: ",") {
        let segments = part.components(separatedBy: ";")
        guard segments.count >= 2 else { continue }
        let hasNextRel = segments.dropFirst().contains { segment in
            segment.trimmingCharacters(in: .whitespaces) == "rel=\"next\""
        }
        guard hasNextRel else { continue }
        if let url = extractURL(from: segments[0]) { return url }
    }
    return nil
}

/// Strips RFC 8288 angle-bracket delimiters from a `Link` header URL segment.
private func extractURL(from segment: String) -> String? {
    let trimmed = segment.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("<"), trimmed.hasSuffix(">") else { return nil }
    return String(trimmed.dropFirst().dropLast())
}
