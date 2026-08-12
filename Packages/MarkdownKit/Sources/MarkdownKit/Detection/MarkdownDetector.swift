// MarkdownDetector.swift
// RunBot
import Markdown

/// Scores a log string for markdown content and decides whether to auto-render it.
///
/// Lives in `MarkdownKit` (not `RunBot`) so it can be unit-tested without SwiftUI.
/// Always pass **ANSI-stripped** text — raw escape sequences degrade AST scoring
/// and would render as literal characters in MarkdownDocumentView. Today `cleanLogText`
/// strips ANSI upstream of this call. When #2379 Item 5 lands and ANSI stripping
/// is extracted into a standalone `stripANSI(_:)` function, the markdown path in
/// `StepLogView.loadLog()` must call `stripANSI(_:)` explicitly. See §7 of #2394.
public enum MarkdownDetector {

    /// The combined result of a single detection pass over a log string.
    ///
    /// Both values are computed from one `Document(parsing:)` call — use `detect(_:)`
    /// rather than calling `confidence(_:)` and `looksLikeMarkdown(_:)` separately.
    public struct DetectResult: Sendable {
        /// Raw confidence score (sum of block-type weights plus diversity bonus).
        public let score: Int
        /// Whether the text passes the mathematical auto-enable gate.
        /// Long logs (> 200 lines) require `S / L >= 0.10`.
        /// Short logs (<= 200 lines) can alternatively pass via `S³ / L >= 1.8`.
        public let looksLikeMarkdown: Bool
    }

    /// Performs a single-pass detection and returns both the raw score and the
    /// auto-enable decision.
    ///
    /// Auto-enable uses a mathematical gate designed to catch short, dense
    /// Markdown responses while still protecting long logs from false positives.
    ///
    /// Mathematical gate:
    /// Requires a minimum score of 3.
    /// Long logs (over 200 lines) must meet a strict density floor (`S / L >= 0.10`).
    /// Short logs (<= 200 lines) can alternatively pass via a cubic curve (`S³ / L >= 1.8`).
    ///
    /// Where:
    /// - `S` = raw score
    /// - `L` = total line count (`max(lines, 1)`)
    ///
    /// Prefer this over calling `confidence(_:)` + `looksLikeMarkdown(_:)` in
    /// sequence — those each call `Document(parsing:)` internally, so using both
    /// doubles the parse work on every log load.
    ///
    /// - Parameter text: ANSI-stripped log text (see type-level doc for contract).
    /// - Returns: A `DetectResult` with the raw score and the boolean gate decision.
    public static func detect(_ text: String) -> DetectResult {
        // Empty input is a valid caller-side condition (e.g. result.text == nil coalesced to "").
        // Short-circuit before Document(parsing:) — an empty AST always scores 0.
        guard !text.isEmpty else { return DetectResult(score: 0, looksLikeMarkdown: false) }
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

        let lines = max(text.components(separatedBy: "\n").count, 1)
        let density = Float(score) / Float(lines)
        let cubic = Float(score * score * score) / Float(lines)
        // Option A: cubic curve only applies to genuinely short logs (<= 200 lines).
        // Long logs must satisfy the density floor; the cubic bypass is capped.
        let autoEnable = score >= 3 && (density >= 0.10 || (cubic >= 1.8 && lines <= 200))
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
    /// - `>= 3` — minimum signal required before any gate applies
    /// - Combined with line-count normalization and the cubic bypass in `looksLikeMarkdown(_:)` for auto-enable
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

    /// Extracts top-level fenced code blocks and their language hints.
    ///
    /// Retained as part of MarkdownDetector's public behavior-preservation contract
    /// from #2600. The current MarkdownLogView prewarmer consumes normalized
    /// MarkdownBlock values instead, so this API may have no in-repository caller.
    /// Do not remove it as dead code without explicitly changing that contract.
    ///
    /// - Parameter text: Raw log text, ANSI-stripped.
    /// - Returns: Array of `(code, language)` tuples; `language` is `nil` when
    ///   no language tag was present on the fence.
    public static func codeBlocks(in text: String) -> [(code: String, language: String?)] {
        let doc = Document(parsing: text)
        var results: [(code: String, language: String?)] = []
        for child in doc.children {
            if let block = child as? CodeBlock {
                results.append((block.code, block.language))
            }
        }
        return results
    }

    /// Returns `true` when `text` is likely markdown and should auto-render.
    ///
    /// Gates (see `detect(_:)` for the authoritative implementation):
    /// 1. Raw score `>= 3` is required.
    /// 2. Then either the density floor (`score / lines >= 0.10`) or, for logs of
    ///    200 lines or fewer, the cubic bypass (`score³ / lines >= 1.8`).
    ///
    /// The density floor prevents a 2000-line build log with a single fenced block
    /// from triggering auto-render. The cubic bypass catches short, dense Markdown
    /// such as a 5-line fenced Swift block (score 4), which the earlier `>= 6`
    /// linear gate rejected.
    ///
    /// - Note: Prefer `detect(_:)` when you need both the score and the boolean
    ///   in the same call site — it avoids a redundant `Document(parsing:)` call.
    public static func looksLikeMarkdown(_ text: String) -> Bool {
        detect(text).looksLikeMarkdown
    }
}
