// MarkdownDetector.swift
// RunBotCore
import Markdown

/// Scores a log string for markdown content and decides whether to auto-render it.
///
/// Lives in `RunBotCore` (not `RunBot`) so it can be unit-tested without SwiftUI.
/// Always pass **ANSI-stripped** text — raw escape sequences degrade AST scoring
/// and would render as literal characters in MarkdownView. Today `cleanLogText`
/// strips ANSI upstream of this call. When #2379 Item 5 lands and ANSI stripping
/// is extracted into a standalone `stripANSI(_:)` function, the markdown path in
/// `StepLogView.loadLog()` must call `stripANSI(_:)` explicitly. See §7 of #2394.
public enum MarkdownDetector {

    /// The combined result of a single detection pass over a log string.
    ///
    /// Both values are computed from one `Document(parsing:)` call — use `detect(_:)`
    /// rather than calling `confidence(_:)` and `looksLikeMarkdown(_:)` separately.
    public struct DetectResult: Sendable {
        /// Raw confidence score. Badge appears when `score >= 6`.
        public let score: Int
        /// Whether the text passes both auto-enable gates.
        public let looksLikeMarkdown: Bool
    }

    /// Performs a single-pass detection and returns both the raw score and the
    /// auto-enable decision.
    ///
    /// Prefer this over calling `confidence(_:)` + `looksLikeMarkdown(_:)` in
    /// sequence — those each call `Document(parsing:)` internally, so using both
    /// doubles the parse work on every log load.
    ///
    /// - Parameter text: ANSI-stripped log text (see type-level doc for contract).
    /// - Returns: A `DetectResult` with the raw score and the boolean gate decision.
    public static func detect(_ text: String) -> DetectResult {
        let doc = Document(parsing: text)
        var score = 0
        var blockTypes = Set<String>()

        for child in doc.children {
            switch child {
            case let cb as CodeBlock:
                score += (cb.language?.isEmpty == false) ? 4 : 1
                blockTypes.insert("code")
            case is Heading:
                score += 2
                blockTypes.insert("heading")
            case is Table:
                score += 3
                blockTypes.insert("table")
            case is UnorderedList, is OrderedList:
                score += 1
                blockTypes.insert("list")
            case is BlockQuote:
                score += 1
                blockTypes.insert("blockquote")
            case let para as Paragraph where para.plainText.count > 80:
                score += 2
                blockTypes.insert("prose")
            default:
                break
            }
        }
        if blockTypes.count >= 3 { score += 3 } // diversity bonus

        let lines = max(text.components(separatedBy: .newlines).count, 1)
        let autoEnable = score >= 6 && Float(score) / Float(lines) >= 0.10
        return DetectResult(score: score, looksLikeMarkdown: autoEnable)
    }

    /// Returns a raw integer score reflecting how markdown-like `text` is.
    ///
    /// Scoring is intentionally top-level only (`doc.children`, not recursive)
    /// so deeply nested inline markup in a plain prose log doesn't trigger
    /// false positives. A diversity bonus (+3) is added when three or more
    /// distinct block types appear.
    ///
    /// Thresholds:
    /// - `>= 6` — enough signal for the badge to appear (§4 of #2394)
    /// - Combined with line-count normalization in `looksLikeMarkdown(_:)` for auto-enable
    ///
    /// - Note: Prefer `detect(_:)` when you need both the score and the boolean
    ///   in the same call site — it avoids a redundant `Document(parsing:)` call.
    ///   ⚠️ Calling `confidence(_:)` and `looksLikeMarkdown(_:)` separately at the
    ///   same call site causes two `Document(parsing:)` calls. This is NOT a bug in
    ///   the detector — it is a caller-side inefficiency. `StepLogView.loadLog()`
    ///   avoids this by calling `detect(_:)` directly and unpacking both fields.
    ///   Do not flag this as a double-parse in the detector itself.
    public static func confidence(_ text: String) -> Int {
        detect(text).score
    }

    /// Returns `true` when `text` is likely markdown and should auto-render.
    ///
    /// Two gates (AND):
    /// 1. Raw score `>= 6`
    /// 2. Normalized score (raw / line count) `>= 0.10` — prevents a 2000-line
    ///    build log with a single fenced block from triggering auto-render.
    ///
    /// - Note: Short-log bypass (open decision, see §2 of #2394):
    ///   A pure 5-line fenced Swift block scores ~4 and fails gate 1 entirely.
    ///   Consider a `lines < 15` fast-pass (`raw >= 4` sufficient) to catch
    ///   clean short AI review outputs. Decide before implementation.
    ///
    /// - Note: Prefer `detect(_:)` when you need both the score and the boolean
    ///   in the same call site — it avoids a redundant `Document(parsing:)` call.
    public static func looksLikeMarkdown(_ text: String) -> Bool {
        detect(text).looksLikeMarkdown
    }
}
