import SwiftUI

/// Explains a connection failure in plain language, with bounded raw details and next steps.
struct ConnectionIssueBanner: View {
    let issue: ConnectionIssue
    var onEdit: (() -> Void)?
    var onReconnect: (() -> Void)?
    /// A single row whose height never depends on the message; details open in a popover.
    var compact = false
    @State private var showsDetails = false

    init(message: String, compact: Bool = false, onEdit: (() -> Void)? = nil, onReconnect: (() -> Void)? = nil) {
        issue = ConnectionIssue.classify(message)
        self.compact = compact
        self.onEdit = onEdit
        self.onReconnect = onReconnect
    }

    private var tint: Color { issue.isSecurityIssue ? .orange : .red }

    var body: some View {
        if compact { compactBody } else { fullBody }
    }

    private var compactBody: some View {
        HStack(spacing: 10) {
            Image(systemName: issue.isSecurityIssue ? "lock.trianglebadge.exclamationmark.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(issue.title).font(.callout.weight(.semibold)).lineLimit(1).layoutPriority(1)
            Text(issue.guidance).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            Button("Show Details") { showsDetails = true }
                .buttonStyle(.borderless)
                .font(.caption)
                .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
                    ConnectionIssueBanner(message: issue.details)
                        .padding(12)
                        .frame(width: 440)
                }
            HStack(spacing: 8) { actionButtons }.controlSize(.small)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 36)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tint.opacity(0.25), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private var fullBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: issue.isSecurityIssue ? "lock.trianglebadge.exclamationmark.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(issue.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PortSQLPalette.ink)
                    Text(issue.guidance)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)

            if showsDetails {
                ScrollView {
                    Text(issue.details)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
                .padding(8)
                .background(PortSQLPalette.sunken, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    detailButtons
                    Spacer(minLength: 0)
                    actionButtons
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) { actionButtons }
                    HStack(spacing: 8) { detailButtons }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tint.opacity(0.25), lineWidth: 1)
        }
    }

    @ViewBuilder private var detailButtons: some View {
        Button(showsDetails ? L10n.text("Hide Details") : L10n.text("Show Details")) {
            withAnimation(.easeOut(duration: 0.15)) { showsDetails.toggle() }
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .frame(minHeight: PortbaseControlSize.minimumHeight)
        Button("Copy Details") { PortbaseClipboard.copy(issue.details) }
            .buttonStyle(.borderless)
            .font(.caption)
            .frame(minHeight: PortbaseControlSize.minimumHeight)
    }

    @ViewBuilder private var actionButtons: some View {
        if let onReconnect {
            Button(action: onReconnect) {
                Label("Reconnect", systemImage: "arrow.clockwise").frame(minHeight: PortbaseControlSize.minimumHeight - 12)
            }
            .buttonStyle(.bordered)
        }
        if let onEdit {
            Button(action: onEdit) {
                Label("Edit Connection", systemImage: "slider.horizontal.3").frame(minHeight: PortbaseControlSize.minimumHeight - 12)
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

extension WorkspaceViewModel {
    /// Opens the editor for the current connection.
    func editCurrentConnection() {
        selectedProfileForEdit = selectedBookmark
    }

    /// Retries the connection by reloading the schema without the cache.
    func reconnect() {
        errorMessage = nil
        reloadSchema(forceRefresh: true)
    }
}
