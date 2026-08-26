// LogLine.swift
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

    /// Creates an `AnnotationParams` with the given optional structured metadata fields.
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
