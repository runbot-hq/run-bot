// PollResultBuilder+Enrichment.swift
// RunBot

/// Enrichment and display helpers for `PollResultBuilder`.
///
/// Extracted from the main file to keep `PollResultBuilder` under the
/// `file_length` lint limit.
extension PollResultBuilder {

  // MARK: - Private helpers

  /// Enriches the display array by running `enrichJobs` over each group's jobs
  /// concurrently via a `withTaskGroup`, preserving the original display sort order.
  ///
  /// `enrichJobs` must be `@escaping` because `addTask` captures it in an escaping closure.
  /// Keyed by `Int` (array index) so the order produced by `buildGroupDisplay` is
  /// faithfully restored after `withTaskGroup` yields results in completion order.
  static func enrichDisplay(
    _ display: [WorkflowActionGroup],
    enrichJobs: @escaping @Sendable ([ActiveJob]) async -> [ActiveJob]
  ) async -> [WorkflowActionGroup] {
    await withTaskGroup(of: (Int, WorkflowActionGroup).self) { group in
      for (idx, actionGroup) in display.enumerated() {
        group.addTask { (idx, actionGroup.withJobs(await enrichJobs(actionGroup.jobs))) }
      }
      var out: [(Int, WorkflowActionGroup)] = []
      for await pair in group { out.append(pair) }
      return out.sorted { $0.0 < $1.0 }.map { $0.1 }
    }
  }

  /// Enriches the group cache by running `enrichJobs` over each cached group's
  /// jobs concurrently via a `withTaskGroup`.
  ///
  /// `enrichJobs` must be `@escaping` because `addTask` captures it in an escaping closure.
  /// Keyed by `String` (group ID) because `newCache` is a dictionary and its
  /// semantic identity IS the group ID. Kept separate from `enrichDisplay` because
  /// the key types differ (Int vs String) and the source collections differ
  /// (display array vs cache dict).
  static func enrichCache(
    _ cache: [String: WorkflowActionGroup],
    enrichJobs: @escaping @Sendable ([ActiveJob]) async -> [ActiveJob]
  ) async -> [String: WorkflowActionGroup] {
    await withTaskGroup(of: (String, WorkflowActionGroup).self) { group in
      for (key, actionGroup) in cache {
        group.addTask { (key, actionGroup.withJobs(await enrichJobs(actionGroup.jobs))) }
      }
      var out: [String: WorkflowActionGroup] = [:]
      for await (key, actionGroup) in group { out[key] = actionGroup }
      return out
    }
  }
}

// MARK: - Array fill helper

/// Sequence-filling helpers used by `PollResultBuilder` to top up display arrays.
extension Array {
  /// Appends elements from `source` until `self.count` reaches `limit`.
  ///
  /// Elements are appended in source order. An optional predicate can skip
  /// individual elements (e.g. cached groups that are already live) without
  /// breaking the "fill until full" semantics.
  ///
  /// Declared inside a `private extension` so it is file-scoped and not
  /// visible outside the `PollResultBuilder` file group. Not intended for use outside
  /// the polling pipeline; treat it as an implementation detail of
  /// `buildJobDisplay` and `buildGroupDisplay`.
  mutating func appendUpTo<S>(
    _ limit: Int,
    from source: S,
    where shouldAppend: (S.Element) -> Bool = { _ in true }
  ) where S: Sequence, S.Element == Element {
    guard count < limit else { return }
    for element in source where count < limit && shouldAppend(element) {
      append(element)
    }
  }
}
