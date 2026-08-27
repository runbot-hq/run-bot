// RepoSelectorSheet.swift
// RunBot
import RunBotCore
import SwiftUI

// MARK: - RepoSelectorSheet
// #580 / #576: Reusable searchable sheet for picking a repository or organisation.
//
// Accepts a pre-loaded list of items (no API calls) and filters them
// client-side via localizedCaseInsensitiveContains, matching the UX
// pattern established by BranchSelectorSheet.
//
// Usage:
// RepoSelectorSheet(
//     items: repos,
//     label: "Repository",
//     onDismiss: { showSheet = false },
//     onSelect: { selectedRepo = $0 }   // do NOT dismiss here; itemRow calls onDismiss
// )

/// Reusable searchable sheet for picking a repository or organisation from a
/// pre-loaded list. Filters client-side. `onSelect` is called with the chosen
/// item string; `onDismiss` is called on every exit path (cancel or after selection).
struct RepoSelectorSheet: View {
    /// The pre-loaded list of item strings to display and filter.
    let items: [String]
    /// Human-readable label shown in the header and search placeholder (e.g. "Repository").
    let label: String
    /// Called on every exit path (selection or cancel).
    let onDismiss: () -> Void
    /// Called with the selected item string. Do NOT call `onDismiss` here -- `itemRow` handles it.
    let onSelect: (String) -> Void

    /// Current search query; filters `items` into `filtered`.
    @State private var searchText = ""

    /// Items matching `searchText` (case-insensitive); equals `items` when `searchText` is empty.
    private var filtered: [String] {
        searchText.isEmpty
            ? items
            : items.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    /// Root body -- header, search field, item list, and cancel footer.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
            searchSection
            Divider()
            listSection
            Divider()
            footerSection
        }
        .frame(width: 360, height: 420)
        .glassCard(cornerRadius: 10)
    }
}

// MARK: - Subviews

/// Subview factories for `RepoSelectorSheet`.
extension RepoSelectorSheet {
    /// Title and subtitle header shown at the top of the sheet.
    var headerSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Select \(label)")
                .font(.system(size: 13, weight: .semibold))
            Text("Choose the \(label.lowercased()) to use as the runner scope.")
                .font(.caption)
                .foregroundColor(Color.rbTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    /// Search field row with clear button.
    var searchSection: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundColor(Color.rbTextTertiary)
            TextField("Search \(label.lowercased())s\u{2026}", text: $searchText)
                .font(.system(size: 12))
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(Color.rbTextTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.rbSurface)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.rbBorderSubtle, lineWidth: 0.5)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    /// Scrollable item list; shows empty-state messages when `items` or `filtered` is empty.
    @ViewBuilder
    var listSection: some View {
        if items.isEmpty {
            HStack {
                Spacer()
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(Color.rbTextTertiary)
                    Text("No \(label.lowercased())s found")
                        .font(.caption)
                        .foregroundColor(Color.rbTextTertiary)
                }
                .padding(.vertical, 40)
                Spacer()
            }
            .frame(maxHeight: .infinity)
        } else if filtered.isEmpty {
            HStack {
                Spacer()
                Text("No results for \"\(searchText)\"")
                    .font(.caption)
                    .foregroundColor(Color.rbTextTertiary)
                    .padding(.vertical, 40)
                Spacer()
            }
            .frame(maxHeight: .infinity)
        } else {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered, id: \.self) { item in
                        itemRow(item)
                        if item != filtered.last {
                            Divider().padding(.leading, 16)
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    /// Row button for a single item. Calls `onSelect` then `onDismiss` on tap.
    func itemRow(_ item: String) -> some View {
        Button(action: {
            log("RepoSelectorSheet \u{203a} selected item='\(item)'")
            onSelect(item)
            onDismiss()
        }) {
            HStack(spacing: 8) {
                Image(systemName: "externaldrive")
                    .font(.system(size: 10))
                    .foregroundColor(Color.rbTextTertiary)
                Text(item)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Color.rbTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Cancel button footer bar.
    var footerSection: some View {
        HStack {
            Spacer()
            Button("Cancel") { onDismiss() }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(Color.rbTextSecondary)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .glassCard(cornerRadius: 6)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 14)
    }
}
