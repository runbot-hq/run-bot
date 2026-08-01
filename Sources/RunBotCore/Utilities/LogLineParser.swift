// LogLineParser.swift
// RunBotCore

// MARK: - AnnotationParams

/// Optional structured metadata attached to a `::warning`, `::error`, or `::notice`
/// annotation line when the `::name params::message` wire format is used.
///
/// All fields are optional — they are omitted when the annotation uses the bare
/// `##[warning]message` format or when the `::` param block is absent.
public struct AnnotationParams: Equatable, Sendable {
    /// The `title=` param — rendered as a bold prefix in the annotation row.
    public let title: String?
    /// The `file=` param — source file path associated with the annotation.
    public let file: String?
    /// The `line=` param — starting line number in `file`.
    public let line: Int?
    /// The `endLine=` param — ending line number in `file` (optional range).
    public let endLine: Int?

    public init(title: String? = nil, file: String? = nil, line: Int? = nil, endLine: Int? = nil) {
        self.title = title
        self.file = file
        self.line = line
        self.endLine = endLine
    }
}

// MARK: - LogLine

/// A single parsed line from a GitHub Actions step log.
///
/// Lines containing `##[group]`, `##[endgroup]`, `##[warning]`, `##[error]`, `##[notice]`,
/// `##[command]`, `##[debug]`, `##[section]`, or their `::` equivalents are parsed into
/// their respective cases. All other lines become `.plain`. Lines inside a group block
/// become `.groupedLine` so the view can hide them when the group is collapsed.
///
/// `::add-mask::` and `::echo::` lines are **filtered out entirely** at parse time and
/// produce no `LogLine` — secret values must never reach the rendered view.
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
    /// A `##[warning]`, `##[error]`, `##[notice]`, `::warning`, `::error`, or `::notice`
    /// annotation line.
    ///
    /// `params` is non-nil when the `::name params::message` wire format is used and
    /// carries optional `title`, `file`, and `line` metadata.
    /// `groupID` is non-nil when the annotation appears inside an open group block.
    case annotation(id: Int, level: AnnotationLevel, text: String, params: AnnotationParams?, groupID: Int?)
    /// A `##[command]`, `##[debug]`, `::debug::`, or unrecognised `##[` directive line —
    /// rendered dimmed in secondary colour.
    ///
    /// `groupID` is non-nil when the directive appears inside an open group block.
    case dimmed(id: Int, text: String, groupID: Int?)
    /// A `##[section]` directive — renders as a bold monospaced heading with a divider above.
    ///
    /// `groupID` is non-nil when the section appears inside an open group block,
    /// consistent with the collapse-gating contract applied to `.annotation` and `.dimmed`.
    case section(id: Int, title: String, groupID: Int?)

    /// Severity level of an annotation line.
    public enum AnnotationLevel: Sendable, Equatable {
        /// `##[warning]` / `::warning` — rendered with an amber left border.
        case warning
        /// `##[error]` / `::error` — rendered with a red left border.
        case error
        /// `##[notice]` / `::notice` — rendered with a secondary-colour left border.
        case notice
    }

    /// The stable identifier required by `Identifiable`.
    public var id: Int {
        switch self {
        case .plain(let id, _),
             .groupHeader(let id, _),
             .groupedLine(let id, _, _),
             .annotation(let id, _, _, _, _),
             .dimmed(let id, _, _),
             .section(let id, _, _):
            return id
        }
    }
}

// MARK: - decodeActionsEscapes

/// Decodes the percent-escape sequences defined by the GitHub Actions toolkit
/// wire format (`command.ts` `escapeProperty` / `escapeData`).
///
/// The five sequences that the toolkit encodes are decoded in the order that
/// avoids double-decoding: `%25` (the escape character itself) must be decoded
/// last so that a literal `%25` in the original string isn't first decoded to
/// `%` and then re-interpreted as the start of another sequence.
///
/// | Encoded | Decoded |
/// |---------|--------|
/// | `%25`   | `%`    |
/// | `%0D`   | `\r`   |
/// | `%0A`   | `\n`   |
/// | `%3A`   | `:`    |
/// | `%2C`   | `,`    |
///
/// This is intentionally minimal — only the sequences the toolkit actually
/// encodes. A generic percent-decode would over-decode.
private func decodeActionsEscapes(_ s: String) -> String {
    // Decode %25 last to avoid double-decoding a literal "%25" in the source.
    s
        .replacingOccurrences(of: "%0D", with: "\r")
        .replacingOccurrences(of: "%0A", with: "\n")
        .replacingOccurrences(of: "%3A", with: ":")
        .replacingOccurrences(of: "%2C", with: ",")
        .replacingOccurrences(of: "%25", with: "%")
}

// MARK: - parseAnnotationParams

/// Parses the `key=value,key=value` parameter block from a `::` annotation line.
///
/// The `::` annotation wire format is:
/// ```
/// ::name key=val,key=val::message
/// ```
/// This function receives only the param block (the substring between `::name ` and
/// the closing `::`). Unknown keys are silently ignored.
///
/// Param values are decoded via `decodeActionsEscapes` — the toolkit's
/// `escapeProperty` encodes `,`→`%2C`, `:`→`%3A`, `\n`→`%0A` in values, so
/// a title like `"Build Error: missing"` arrives as `"Build Error%3A missing"`
/// and must be decoded before display.
///
/// - Parameter block: The raw parameter substring, e.g. `"file=app.js,line=12,title=Lint Error"`.
/// - Returns: An `AnnotationParams` if at least one recognised key is present, otherwise `nil`.
public func parseAnnotationParams(_ block: String) -> AnnotationParams? {
    guard !block.isEmpty else { return nil }
    var title: String?
    var file: String?
    var line: Int?
    var endLine: Int?
    // Params are comma-separated key=value pairs. Values may not contain unescaped commas
    // (the toolkit percent-encodes them as %2C), so splitting on "," is safe.
    for pair in block.components(separatedBy: ",") {
        let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { continue }
        let key = parts[0].trimmingCharacters(in: .whitespaces)
        let value = parts[1].trimmingCharacters(in: .whitespaces)
        switch key {
        case "title":   title = decodeActionsEscapes(value)
        case "file":    file = decodeActionsEscapes(value)
        case "line":    line = Int(value)
        case "endLine": endLine = Int(value)
        default: break
        }
    }
    guard title != nil || file != nil || line != nil || endLine != nil else { return nil }
    return AnnotationParams(title: title, file: file, line: line, endLine: endLine)
}

// MARK: - parseLogLines

/// Parses a cleaned step log string into an array of typed `LogLine` values.
///
/// **Input contract:** `raw` should already have been processed by `cleanLogText`
/// (timestamps and `\r` stripped). ANSI escape sequences are also stripped by
/// `cleanLogText` for now; they will be preserved once the ANSI renderer lands.
///
/// **Directive formats handled:**
/// - `##[group]` / `##[endgroup]` — collapsible group
/// - `##[warning]` / `##[error]` / `##[notice]` — annotation (bare format)
/// - `::warning params::msg` / `::error params::msg` / `::notice params::msg` — annotation with params
/// - `##[command]` / `##[debug]` / `::debug::` — dimmed runner internals
/// - `##[section]` — bold section heading with divider
/// - `::add-mask::` / `::echo::` — **filtered out entirely** (no `LogLine` emitted)
/// - Any other `##[` prefix — dimmed (runner-internal noise)
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
        // ── ##[ directives (old runner wire format) ──────────────────────────
        if line.hasPrefix("##[group]") {
            // Implicit close of any previously open group (GitHub Actions behaviour).
            currentGroupID = nil
            let title = String(line.dropFirst("##[group]".count)).trimmingCharacters(in: .whitespaces)
            let id = makeID()
            result.append(.groupHeader(id: id, title: title))
            currentGroupID = id
        } else if line.hasPrefix("##[endgroup]") {
            currentGroupID = nil
        } else if line.hasPrefix("##[section]") {
            let title = String(line.dropFirst("##[section]".count)).trimmingCharacters(in: .whitespaces)
            result.append(.section(id: makeID(), title: title, groupID: currentGroupID))
        } else if line.hasPrefix("##[warning]") {
            let text = String(line.dropFirst("##[warning]".count)).trimmingCharacters(in: .whitespaces)
            result.append(.annotation(id: makeID(), level: .warning, text: text, params: nil, groupID: currentGroupID))
        } else if line.hasPrefix("##[error]") {
            let text = String(line.dropFirst("##[error]".count)).trimmingCharacters(in: .whitespaces)
            result.append(.annotation(id: makeID(), level: .error, text: text, params: nil, groupID: currentGroupID))
        } else if line.hasPrefix("##[notice]") {
            let text = String(line.dropFirst("##[notice]".count)).trimmingCharacters(in: .whitespaces)
            result.append(.annotation(id: makeID(), level: .notice, text: text, params: nil, groupID: currentGroupID))
        } else if line.hasPrefix("##[command]") {
            let text = String(line.dropFirst("##[command]".count)).trimmingCharacters(in: .whitespaces)
            result.append(.dimmed(id: makeID(), text: text, groupID: currentGroupID))
        } else if line.hasPrefix("##[debug]") {
            let text = String(line.dropFirst("##[debug]".count)).trimmingCharacters(in: .whitespaces)
            result.append(.dimmed(id: makeID(), text: text, groupID: currentGroupID))
        } else if line.hasPrefix("##[") {
            // Catch-all for unrecognised ##[ directives (add-matcher, remove-matcher,
            // stop-commands, start-commands, etc.) — route to .dimmed.
            result.append(.dimmed(id: makeID(), text: line, groupID: currentGroupID))

        // ── :: directives (new runner wire format) ───────────────────────────
        } else if line.hasPrefix("::") {
            // Filter: these meta-commands carry no display value and must produce
            // no LogLine. ::add-mask:: must never expose the secret value.
            // Case-insensitive: the C# runner accepts any casing; the toolkit emits
            // lowercase canonically, but a raw echo in a workflow can use any case.
            let lower = line.lowercased()
            if lower.hasPrefix("::add-mask::") || lower.hasPrefix("::echo::") {
                continue
            } else if lower.hasPrefix("::debug::") {
                let text = String(line.dropFirst("::debug::".count)).trimmingCharacters(in: .whitespaces)
                result.append(.dimmed(id: makeID(), text: text, groupID: currentGroupID))
            } else if let annotation = parseColonAnnotation(line) {
                result.append(.annotation(id: makeID(), level: annotation.level, text: annotation.text, params: annotation.params, groupID: currentGroupID))
            } else {
                // Unknown :: directive — dimmed.
                result.append(.dimmed(id: makeID(), text: line, groupID: currentGroupID))
            }

        // ── plain / grouped ──────────────────────────────────────────────────
        } else if let groupID = currentGroupID {
            result.append(.groupedLine(id: makeID(), text: line, groupID: groupID))
        } else {
            result.append(.plain(id: makeID(), text: line))
        }
    }

    return result
}

// MARK: - ColonAnnotation (internal)

/// Parsed result of a `::warning`, `::error`, or `::notice` annotation line.
private struct ColonAnnotation {
    /// The severity level derived from the directive keyword.
    let level: LogLine.AnnotationLevel
    /// Optional structured metadata parsed from the param block, or `nil` when absent.
    let params: AnnotationParams?
    /// The message text following the closing `::` separator.
    let text: String
}

// MARK: - parseColonAnnotation (internal)

/// Attempts to parse a `::warning`, `::error`, or `::notice` annotation line.
///
/// Expected format: `::level params::message` or `::level::message`.
///
/// The message text is decoded via `decodeActionsEscapes` — `command.ts`
/// `escapeData` encodes `%`→`%25`, `\r`→`%0D`, `\n`→`%0A` in the message.
///
/// - Returns: A `ColonAnnotation` on success, or `nil` if the line does not
///   match a known annotation level.
private func parseColonAnnotation(_ line: String) -> ColonAnnotation? {
    let levelMap: [(String, LogLine.AnnotationLevel)] = [
        ("::warning", .warning),
        ("::error", .error),
        ("::notice", .notice),
    ]
    // Case-insensitive matching: ActionCommandManager.cs uses StringComparer.OrdinalIgnoreCase
    // for its command dictionary, so ::Warning:: and ::ERROR:: are valid. We match against
    // the lowercased line but extract text from the original to preserve message casing.
    let lineLower = line.lowercased()
    for (prefix, level) in levelMap {
        guard lineLower.hasPrefix(prefix) else { continue }
        // Word-boundary guard: the character after the level keyword must be a space
        // (params block follows) or `:` (bare `::` separator). This prevents
        // `::warning-extra::msg` from false-matching the `::warning` prefix.
        let afterLevel = String(line.dropFirst(prefix.count))
        guard afterLevel.hasPrefix(" ") || afterLevel.hasPrefix(":") else { continue }
        // Find the closing "::" that separates params from message.
        // The Actions runner spec (toolkit/command.ts) requires that param values
        // must not themselves contain "::" — if they did, this range(of:) would
        // find the wrong separator and silently truncate the param block.
        guard let separatorRange = afterLevel.range(of: "::") else { continue }
        let paramBlock = String(afterLevel[afterLevel.startIndex ..< separatorRange.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        let rawText = String(afterLevel[separatorRange.upperBound...])
            .trimmingCharacters(in: .whitespaces)
        let params = parseAnnotationParams(paramBlock)
        return ColonAnnotation(level: level, params: params, text: decodeActionsEscapes(rawText))
    }
    return nil
}
