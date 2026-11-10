import Charts
import Security
import SwiftUI
import UniformTypeIdentifiers

struct SectionHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(title)
                .font(.sectionTitle)
                .foregroundStyle(PortSQLPalette.ink)
                .accessibilityAddTraits(.isHeader)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.footnoteText)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

struct PanelCard<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.workspaceIsFlat) private var flat

    var body: some View {
        if flat {
            // On phones: a full-width section with a divider below, not a card inside the page's padding.
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.s)
            .background(PortSQLPalette.surface)
            .overlay(alignment: .bottom) { Rectangle().fill(PortSQLPalette.stroke).frame(height: 1) }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.card)
            .portbaseCardSurface()
        }
    }
}
/// A failure or warning as one flat line: a tinted symbol, then what happened and why. No box or colored
/// background, so a warning reads as part of the section it belongs to.
struct StatusBanner: View {
    let title: String
    let message: String
    let tint: Color
    var titleColor: Color = PortSQLPalette.ink
    var messageColor: Color = .secondary

    private var symbol: String {
        switch tint {
        case .red: "xmark.octagon.fill"
        case .orange, .yellow: "exclamationmark.triangle.fill"
        case .green: "checkmark.circle.fill"
        default: "info.circle.fill"
        }
    }

    var body: some View {
        Label {
            (Text(title).fontWeight(.semibold).foregroundColor(titleColor)
                + Text(verbatim: " ")
                + Text(message).foregroundColor(messageColor))
                .font(.captionText)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Spacing.xs)
        .accessibilityElement(children: .combine)
    }
}

struct InlineSuggestionItem: Hashable {
    let title: String
    let subtitle: String?
    var symbol: String?
    var tint: Color?
}

struct InlineSuggestionMenu: View {
    let suggestions: [InlineSuggestionItem]
    let onSelect: (InlineSuggestionItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.s) {
                    ForEach(Array(suggestions.enumerated()), id: \.offset) { _, item in
                        Button {
                            onSelect(item)
                        } label: {
                            HStack(spacing: Spacing.xs) {
                                if let symbol = item.symbol {
                                    Image(systemName: symbol)
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(item.tint ?? PortSQLPalette.muted)
                                }
                                Text(item.title)
                                    .font(.codeCaption)
                                    .foregroundStyle(PortSQLPalette.ink)
                                    .lineLimit(1)
                                if let subtitle = item.subtitle, !subtitle.isEmpty {
                                    Text(subtitle)
                                        .font(.captionText)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .padding(.horizontal, Spacing.s)
                            .padding(.vertical, Spacing.xs)
                            .background(PortSQLPalette.sunken, in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
                            .overlay { RoundedRectangle(cornerRadius: Radius.chip, style: .continuous).strokeBorder(PortSQLPalette.stroke, lineWidth: 1) }
                            // A compact tag that still keeps a full-size touch target.
                            .frame(minHeight: Sizes.control)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.format("Insert %@", item.title))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct WorkbenchBackground: View {
    var body: some View {
        PortbaseBackdrop()
    }
}
