// LogFetcher+Models.swift
// RunBotCore
import Foundation

// MARK: - StepLogResult

/// Typed result from step log extraction.
/// Every case is distinct — wrong content can never silently look like correct content.
public enum StepLogResult: Equatable, Sendable {
    /// ZIP file found and matched by {sanitisedJobName}/{stepNumber}_*.txt.
    case slice(content: String)
    /// ZIP contained no per-step files for this job — flat blob used instead.
    /// StepLogView MUST render a visible degradation notice for this case.
    case flatBlobFallback(content: String)
    /// Step produced no output (ZIP file present but empty, or step not found).
    case syntheticEmpty(stepName: String, reason: String)
    /// Network failure, ZIP parse failure, or subprocess failure.
    case fetchFailed(reason: String)

    /// The log text to display, or nil if there is nothing to show.
    public var text: String? {
        switch self {
        case .slice(let content), .flatBlobFallback(let content): return content
        case .syntheticEmpty, .fetchFailed: return nil
        }
    }

    /// True when this result represents a step that was intentionally skipped by the runner
    /// (as opposed to a fetch failure or a step that ran but produced no output).
    /// StepLogView uses this to render a neutral “Step skipped” headline instead of
    /// the error-toned “No output recorded” headline.
    public var isSkipped: Bool {
        guard case .syntheticEmpty(_, let reason) = self else { return false }
        return reason.hasPrefix("This step was skipped")
    }
}

// MARK: - UnzipResult

/// Typed result from `unzipLogs(_:)` — distinguishes subprocess failure from empty archive.
public enum UnzipResult: Sendable {
    /// ZIP extracted successfully; contains (relative path, text) pairs for every `.txt` file found.
    case success([(name: String, text: String)])
    /// `/usr/bin/unzip` exited with a non-zero status. The associated value is the raw exit code.
    case processFailed(exitCode: Int32)
    /// A filesystem operation failed (directory creation, file write, or enumeration).
    case ioError
}

/// A closure that extracts a ZIP archive (`Data`) into named text file entries.
/// The default implementation spawns `/usr/bin/unzip`; tests inject a stub.
public typealias ZipExtractor = @Sendable (Data) async -> UnzipResult
