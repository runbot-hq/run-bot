// GitHubResponseDecoder.swift
// GitHubClient

import Foundation

public func logErrorBody(_ data: Data?, endpoint: String, status: Int) {
  guard let data, !data.isEmpty else { return }
  let body = String(data: data, encoding: .utf8) ?? "<non-UTF8, \(data.count)b>"
  let preview = body.count > 400 ? String(body.prefix(400)) + "…" : body
  log("HTTP \(status) \(endpoint): \(preview)", category: .transport)
}

public func handleRateLimitResponse(
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
  guard isRealRateLimit else {
    log("RateLimit › 403 permission error (not rate limit) — \(endpoint)", category: .transport)
    return false
  }

  let limitKind = rateLimitKind(retryAfter: retryAfter, statusCode: statusCode)
  logErrorBody(data, endpoint: endpoint, status: statusCode)

  let resetAt = resetTimestamp(retryAfter: retryAfter, resetHeader: resetHeader)
  log(
    "RateLimit › ⚠️ rate limited (\(limitKind)) — \(endpoint) "
      + "status=\(statusCode) "
      + "retryAfter=\(String(describing: retryAfter)) "
      + "resetAt=\(String(describing: resetAt))",
    category: .transport
  )
  await rateLimiter.set(resetAt: resetAt)
  return true
}

private func rateLimitKind(retryAfter: Double?, statusCode: Int) -> String {
  retryAfter != nil || statusCode == 429 ? "secondary" : "primary"
}

private func resetTimestamp(retryAfter: Double?, resetHeader: TimeInterval?) -> TimeInterval? {
  if let retryAfter {
    return Date().timeIntervalSince1970 + retryAfter
  }
  return resetHeader
}

public func extractNextURL(from header: String?) -> String? {
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

private func extractURL(from segment: String) -> String? {
  let trimmed = segment.trimmingCharacters(in: .whitespaces)
  guard trimmed.hasPrefix("<"), trimmed.hasSuffix(">") else { return nil }
  return String(trimmed.dropFirst().dropLast())
}
