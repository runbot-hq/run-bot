// LogPlainLine.swift
// RunBot
import SwiftUI

/// A single plain log line rendered in monospaced text.
///
/// `textSelection` is applied at the parent `LazyVStack` level; this view does not
/// need to set it individually.
struct LogPlainLine: View {
    /// The log line text to display.
    let text: String

    /// The view body.
    var body: some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(Color.rbTextPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}
