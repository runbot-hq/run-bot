// GitHubResponseDecoder.swift
// GitHubClient

import Foundation

// MARK: - Error logging

/// Logs the response body (up to 400 chars) for non-2xx responses.
func logErrorBody(_ data: Data?, endpoint: String, status: Int) {
  guard let data, !data.isEmpty else { return }
  // Intentionally silent in the package — no module-level logger available.
  // RunBotCore can observe errors via the ExecuteResult return value.
  _ = data
}

// MARK: - Rate-limit response handler

/// Handles a 403 or 429 rate-limit response by forwarding to the given `RateLimitActorProtocol`.
///
/// Only arms the actor when the response is a genuine rate-limit signal:
/// - HTTP 429 (always a rate-limit by definition)
/// - HTTP 403 with `X-RateLimit-Remaining: 0` (primary rate limit exhausted)
/// - HTTP 403 with a `Retry-After` header (secondary / abuse rate limit)
///
/// - Returns: `true` when this response was a genuine rate limit and the actor
///   was armed; `false` when the 403 is a plain permission error.
func handleRateLimitResponse(
  statusCode: Int,
  _ data: Data?,
  response: HTTPURLResponse,
  endpoint: String,
  rateLimiter: some RateLimitActorProtocol
) async -> Bool {
  let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
  let remaining = response.value(forHTTPHeaderField: "X-RateLimit-Remaining").flatMap(Int.init)
  let resetHeader = response.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(TimeInterval.init)

  let isRealRateLimit = statusCode == 429 || remaining == 0 || retryAfter != nil
  guard isRealRateLimit else { return false }

  logErrorBody(data, endpoint: endpoint, status: statusCode)
  let resetAt = resetTimestamp(retryAfter: retryAfter, resetHeader: resetHeader)
  await rateLimiter.set(resetAt: resetAt)
  return true
}

/// Returns `"secondary"` for 429s or responses with a `Retry-After` header;
/// returns `"primary"` for quota-exhausted 403s.
private func rateLimitKind(retryAfter: Double?, statusCode: Int) -> String {
  retryAfter != nil || statusCode == 429 ? "secondary" : "primary"
}

/// Computes the absolute reset timestamp from the rate-limit response headers.
private func resetTimestamp(retryAfter: Double?, resetHeader: TimeInterval?) -> TimeInterval? {
  if let retryAfter {
    return Date().timeIntervalSince1970 + retryAfter
  }
  return resetHeader
}

// MARK: - Pagination

/// Parses the `Link` header from a GitHub paginated response and returns the `next` URL, if any.
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
private func extractURL(from segment: String) -> String? {
  let trimmed = segment.trimmingCharacters(in: .whitespaces)
  guard trimmed.hasPrefix("<"), trimmed.hasSuffix(">") else { return nil }
  return String(trimmed.dropFirst().dropLast())
}
