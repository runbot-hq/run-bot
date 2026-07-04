// GitHubResponseDecoder.swift
// GitHubClient

import Foundation

// MARK: - Error logging

/// Logs the response body (up to 400 chars) for non-2xx responses.
/// - Parameter logger: The injected logger, or `nil` to suppress output.
func logErrorBody(_ data: Data?, endpoint: String, status: Int, logger: (any GitHubLogger)?) {
  guard let data, !data.isEmpty else { return }
  let body = String(data: data, encoding: .utf8) ?? "<non-UTF8, \(data.count)b>"
  let preview = body.count > 400 ? String(body.prefix(400)) + "…" : body
  logger?.log("HTTP \(status) \(endpoint): \(preview)", category: "transport")
}

// MARK: - Rate-limit response handler

/// Handles a 403 or 429 rate-limit response by forwarding to the given `RateLimitActorProtocol`.
///
/// Only arms the actor when the response is a **genuine** rate-limit signal:
/// - HTTP 429 (always a rate-limit by definition)
/// - HTTP 403 with `X-RateLimit-Remaining: 0` (primary rate limit exhausted)
/// - HTTP 403 with a `Retry-After` header (secondary / abuse rate limit)
///
/// A plain 403 with none of those signals is a **permission error** (wrong token
/// scope, revoked PAT, repo access denial) and must **not** arm the actor—
/// doing so would lock the app out of the API for up to 60 minutes even though
/// no rate limit was hit.
///
/// - Returns: `true` when this response was a genuine rate limit **and** the actor
///   was armed; `false` when the 403 is a plain permission error and the actor was
///   left unchanged. Callers **must** use this return value to classify the result
///   as `.rateLimited` vs `.permissionDenied`—reading the actor after the call
///   is a TOCTOU: a prior concurrent request may have already armed the actor,
///   causing a permission-denied 403 to be misclassified as a rate-limit.
///
/// - Parameter statusCode: The HTTP status code of the response.
/// - Parameter data: The response body, if any.
/// - Parameter response: The full `HTTPURLResponse`.
/// - Parameter endpoint: The endpoint string, used for logging.
/// - Parameter rateLimiter: The rate-limit actor to arm on a genuine rate-limit response.
///   **No default is provided intentionally.** This function is internal and
///   must always be called from `urlSessionExecute`, which threads its own
///   injected actor through.
/// - Parameter logger: The injected logger, or `nil` to suppress output.
///
/// - Important: Do not call this function directly from outside `urlSessionExecute`.
///
/// See https://docs.github.com/en/rest/overview/rate-limits-for-the-rest-api
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

  // A 429 is always a rate limit; a 403 is only a rate limit when
  // Remaining == 0 or a Retry-After window is present.
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

/// Returns `"secondary"` for 429s or responses with a `Retry-After` header;
/// returns `"primary"` for quota-exhausted 403s (`X-RateLimit-Remaining: 0`).
///
/// Primary = quota exhausted—wait for the reset window.
/// Secondary = abuse / concurrency throttle—back off from request rate.
private func rateLimitKind(retryAfter: Double?, statusCode: Int) -> String {
  retryAfter != nil || statusCode == 429 ? "secondary" : "primary"
}

/// Computes the absolute reset timestamp from the rate-limit response headers.
///
/// Prefers `Retry-After` (a relative delay in seconds added to `now`) over the
/// absolute `X-RateLimit-Reset` epoch value.
private func resetTimestamp(retryAfter: Double?, resetHeader: TimeInterval?) -> TimeInterval? {
  if let retryAfter {
    return Date().timeIntervalSince1970 + retryAfter
  }
  return resetHeader
}

// MARK: - Pagination

/// Parses the `Link` header from a GitHub paginated response and returns the `next` URL, if any.
///
/// Scans all semicolon-delimited tokens after the URL so `rel="next"` is found regardless
/// of its position in a multi-parameter Link part (RFC 8288 compliant).
func extractNextURL(from header: String?) -> String? {
  guard let header else { return nil }
  for part in header.components(separatedBy: ",") {
    let segments = part.components(separatedBy: ";")
    guard segments.count >= 2 else { continue }
    let hasNextRel = segments.dropFirst().contains {
      $0.trimmingCharacters(in: .whitespaces) == "rel=\"next\""
    }
    guard hasNextRel else { continue }
    if let url = extractURL(from: segments[0]) { return url }
  }
  return nil
}

/// Strips the RFC 8288 angle-bracket delimiters from a `Link` header URL segment.
///
/// Returns the bare URL string when the segment is in `<url>` form, or `nil` otherwise.
private func extractURL(from segment: String) -> String? {
  let trimmed = segment.trimmingCharacters(in: .whitespaces)
  guard trimmed.hasPrefix("<"), trimmed.hasSuffix(">") else { return nil }
  return String(trimmed.dropFirst().dropLast())
}
