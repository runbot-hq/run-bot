// MigrationDetailCard.swift
// RunBot

import SwiftUI

// MARK: - MigrationDetailCard helpers

/// Rounded filled card with a compact section heading above it.
///
/// Shared by `MigrationRunnerDetailView` and `MigrationScopeDetailView`
/// to eliminate duplicated layout helpers. (#2920)
func migrationDetailSection<Content: View>(
    title: String,
    @ViewBuilder content: () -> Content
) -> some View {
    VStack(alignment: .leading, spacing: 10) {
        Text(title)
            .font(.system(size: 15, weight: .semibold))

        VStack(spacing: 0) {
            content()
        }
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(Color.rbSettingsCardBackground)
        )
    }
}

/// Standard two-line label / value row.
///
/// `valueColor` defaults to `.secondary`; pass `Color.rbSuccess` etc. for
/// semantic state colours.
func migrationDetailRow(
    title: String,
    description: String,
    value: String,
    valueColor: Color = .secondary
) -> some View {
    HStack(alignment: .center, spacing: 24) {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 15, weight: .medium))
            Text(description)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Spacer(minLength: 24)

        Text(value)
            .font(.system(size: 14))
            .foregroundStyle(valueColor)
            .multilineTextAlignment(.trailing)
            .textSelection(.enabled)
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 15)
    .frame(minHeight: 72)
}

/// Two-line label / value row with an inline copy button; used for URLs.
func migrationCopyableDetailRow(
    title: String,
    description: String,
    value: String
) -> some View {
    HStack(alignment: .center, spacing: 24) {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 15, weight: .medium))
            Text(description)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Spacer(minLength: 24)

        Text(value)
            .font(.system(size: 14))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)

        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        } label: {
            Image(systemName: "doc.on.doc")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Copy to clipboard")
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 15)
    .frame(minHeight: 72)
}

/// Subtle one-point inset separator between card rows.
func migrationRowDivider() -> some View {
    Rectangle()
        .fill(Color.primary.opacity(0.12))
        .frame(height: 1)
        .padding(.horizontal, 20)
}
