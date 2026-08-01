// LogLineParser.swift
// RunBotCore

// MARK: - LogLine

/// A single parsed line from a GitHub Actions step log.
///
/// Lines containing `##[group]`, `##[endgroup]`, `##[warning]`, `##[error]`, or
/// `##[notice]` directives are parsed into their respective cases. All other lines
/// become `.plain`. Lines inside a group block become `.groupedLine` so the view
/// can hide them when the group is collapsed.
///
/// IDs are assigned by `parseLogLines` using a monotonic counter and are stable
/// within a single parse pass. They are not persisted and must not be compared
/// across separate parse calls.
public enum LogLine: Identifiable, Equatable, Sendable {
    /// A regular log line with no directive prefix.
    case plain(id: Int, text: String)
    /// A `##[group]Title` directive — renders as a collapsible chevron row.
    case groupHeader(id: Int, title: String)
    /// A line that falls between a `##[group]` and `##[endgroup]` pair.
    /// `groupID` is the `id` of the owning `groupHeader`.
    case groupedLine(id: Int, text: String, groupID: Int)
    /// A `##[warning]`, `##[error]`, or `##[notice]` annotation line.
    case annotation(id: Int, level: AnnotationLevel, text: String)

    /// Severity level of an annotation line.
    public enum AnnotationLevel: Sendable, Equatable {
        /// `##[warning]` — rendered with an amber left border.
        case warning
        /// `##[error]` — rendered with a red left border.
        case error
        /// `##[notice]` — rendered with a secondary-colour left border.
        case notice
    }

    /// The stable identifier required by `Identifiable`.
    public var id: Int {
        switch self {
        case .plain(let id, _),
             .groupHeader(let id, _),
             .groupedLine(let id, _, _),
             .annotation(let id, _, _):
            return id
        }
    }
}

// MARK: - parseLogLines

/// Parses a cleaned step log string into an array of typed `LogLine` values.
///
/// **Input contract:** `raw` should already have been processed by `cleanLogText`
/// (ANSI escapes and timestamps stripped). `##[group]` / `##[endgroup]` / annotation
/// directives survive `cleanLogText` unchanged and are parsed here.
///
/// **Group nesting:** GitHub Actions does not support nested groups; only one group
/// is tracked at a time. An `##[endgroup]` with no matching open group is ignored.
/// A second `##[group]` while one is already open implicitly closes the previous one.
///
/// - Parameter raw: The cleaned log text to parse.
/// - Returns: An array of `LogLine` values in document order, suitable for
///   direct use in a `ForEach`.
public func parseLogLines(_ raw: String) -> [LogLine] {
    var result: [LogLine] = []
    var nextID = 0
    var currentGroupID: Int?

    func makeID() -> Int {
        let id = nextID
        nextID += 1
        return id
    }

    let lines = raw.components(separatedBy: "\n")
    // Drop a trailing empty line produced by a trailing newline so it doesn't
    // render as a blank row at the bottom of every log.
    let trimmed = lines.last == "" ? lines.dropLast() : lines[...]

    for line in trimmed {
        if line.hasPrefix("##[group]") {
            // Implicit close of any previously open group (GitHub Actions behaviour).
            currentGroupID = nil
            let title = String(line.dropFirst("##[group]".count))
            let id = makeID()
            result.append(.groupHeader(id: id, title: title))
            currentGroupID = id
        } else if line.hasPrefix("##[endgroup]") {
            currentGroupID = nil
        } else if line.hasPrefix("##[warning]") {
            let text = String(line.dropFirst("##[warning]".count))
            result.append(.annotation(id: makeID(), level: .warning, text: text))
        } else if line.hasPrefix("##[error]") {
            let text = String(line.dropFirst("##[error]".count))
            result.append(.annotation(id: makeID(), level: .error, text: text))
        } else if line.hasPrefix("##[notice]") {
            let text = String(line.dropFirst("##[notice]".count))
            result.append(.annotation(id: makeID(), level: .notice, text: text))
        } else if let groupID = currentGroupID {
            result.append(.groupedLine(id: makeID(), text: line, groupID: groupID))
        } else {
            result.append(.plain(id: makeID(), text: line))
        }
    }

    return result
}
