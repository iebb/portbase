import SwiftUI

/// Explains a connection failure in plain language, with bounded raw details and next steps.
struct ConnectionIssueBanner: View {
    let issue: ConnectionIssue
    var onEdit: (() -> Void)?
    var onReconnect: (() -> Void)?
    /// Opens the server's CA for review; shown for untrusted certificates.
    var onReviewCertificate: (() -> Void)?
    /// A single row whose height never depends on the message; details open in a popover.
    var compact = false
    @State private var showsDetails = false

    init(message: String, compact: Bool = false, onEdit: (() -> Void)? = nil, onReconnect: (() -> Void)? = nil,
         onReviewCertificate: (() -> Void)? = nil) {
        issue = ConnectionIssue.classify(message)
        self.compact = compact
        self.onEdit = onEdit
        self.onReconnect = onReconnect
        self.onReviewCertificate = onReviewCertificate
    }

    private var tint: Color { issue.isSecurityIssue ? .orange : .red }

    var body: some View {
        if compact { compactBody } else { fullBody }
    }

    private var compactBody: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: issue.isSecurityIssue ? "lock.trianglebadge.exclamationmark.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(issue.title).font(.rowDetail.weight(.semibold)).lineLimit(1).layoutPriority(1)
            Text(issue.guidance).font(.captionText).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: Spacing.s)
            Button("Show Details") { showsDetails = true }
                .buttonStyle(.borderless)
                .font(.captionText)
                .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
                    ConnectionIssueBanner(message: issue.details)
                        .padding(Spacing.m)
                        .frame(width: 440)
                }
            HStack(spacing: Spacing.s) { actionButtons }.controlSize(.small)
        }
        .padding(.horizontal, Spacing.m)
        .frame(minHeight: Sizes.statusBar)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.chip, style: .continuous).strokeBorder(tint.opacity(0.25), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private var fullBody: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(alignment: .top, spacing: Spacing.s) {
                Image(systemName: issue.isSecurityIssue ? "lock.trianglebadge.exclamationmark.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(issue.title)
                        .font(.rowTitle)
                        .foregroundStyle(PortSQLPalette.ink)
                    Text(issue.guidance)
                        .font(.captionText)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)

            if showsDetails {
                ScrollView {
                    Text(issue.details)
                        .font(.codeCaption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
                .padding(Spacing.s)
                .background(PortSQLPalette.sunken, in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: Spacing.s) {
                    detailButtons
                    Spacer(minLength: 0)
                    actionButtons
                }
                VStack(alignment: .leading, spacing: Spacing.s) {
                    HStack(spacing: Spacing.s) { actionButtons }
                    HStack(spacing: Spacing.s) { detailButtons }
                }
            }
        }
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(tint.opacity(0.25), lineWidth: 1)
        }
    }

    @ViewBuilder private var detailButtons: some View {
        Button(showsDetails ? L10n.text("Hide Details") : L10n.text("Show Details")) {
            withAnimation(.easeOut(duration: 0.15)) { showsDetails.toggle() }
        }
        .buttonStyle(.borderless)
        .font(.captionText)
        .frame(minHeight: Sizes.control)
        Button("Copy Details") { PortbaseClipboard.copy(issue.details) }
            .buttonStyle(.borderless)
            .font(.captionText)
            .frame(minHeight: Sizes.control)
    }

    @ViewBuilder private var actionButtons: some View {
        if let onReviewCertificate, issue.kind == .certificateUntrusted {
            Button(action: onReviewCertificate) {
                Label("Review Certificate", systemImage: "lock.shield").frame(minHeight: Sizes.control - 12)
            }
            .buttonStyle(.borderedProminent)
        }
        if let onReconnect {
            Button(action: onReconnect) {
                Label("Reconnect", systemImage: "arrow.clockwise").frame(minHeight: Sizes.control - 12)
            }
            .buttonStyle(.bordered)
        }
        if let onEdit {
            Button(action: onEdit) {
                Label("Edit Connection", systemImage: "slider.horizontal.3").frame(minHeight: Sizes.control - 12)
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
