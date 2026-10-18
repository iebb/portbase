import SwiftUI

extension View {
    /// Asks before running SQL that writes or destroys data. Destructive statements (DROP, TRUNCATE,
    /// DELETE without WHERE) get a dedicated prompt naming what is lost; other writes keep the alert.
    func sqlSafetyConfirmation(_ workspace: WorkspaceViewModel) -> some View {
        modifier(SQLSafetyConfirmationModifier(workspace: workspace))
    }
}

private struct SQLSafetyConfirmationModifier: ViewModifier {
    @ObservedObject var workspace: WorkspaceViewModel

    private var ordinary: Binding<PendingSQLExecution?> {
        Binding(get: { workspace.pendingSafetyConfirmation.flatMap { $0.assessment.isDestructive ? nil : $0 } },
                set: { if $0 == nil, workspace.pendingSafetyConfirmation?.assessment.isDestructive == false { workspace.cancelPendingSafetyConfirmation() } })
    }

    private var destructive: Binding<PendingSQLExecution?> {
        Binding(get: { workspace.pendingSafetyConfirmation.flatMap { $0.assessment.isDestructive ? $0 : nil } },
                set: { if $0 == nil, workspace.pendingSafetyConfirmation?.assessment.isDestructive == true { workspace.cancelPendingSafetyConfirmation() } })
    }

    func body(content: Content) -> some View {
        content
            .alert(item: ordinary) { pending in
                Alert(title: Text(pending.assessment.title), message: Text(pending.assessment.message),
                      primaryButton: .destructive(Text("Run Anyway")) { workspace.runPendingSafetyConfirmation() },
                      secondaryButton: .cancel { workspace.cancelPendingSafetyConfirmation() })
            }
            .sheet(item: destructive) { pending in
                DestructiveSQLConfirmationSheet(
                    pending: pending,
                    connection: [workspace.selectedBookmark?.displayTitle, workspace.activeDatabaseName].compactMap { $0 }.joined(separator: " · "),
                    environment: workspace.selectedBookmark?.environment ?? .none,
                    onConfirm: { workspace.runPendingSafetyConfirmation() },
                    onCancel: { workspace.cancelPendingSafetyConfirmation() }
                )
#if os(macOS)
                .frame(width: 520)
                .frame(minHeight: 360)
#else
                .presentationDetents([.medium, .large])
#endif
                .interactiveDismissDisabled()
            }
    }
}

/// Names what a destructive statement removes, shows the SQL, and on production connections asks the
/// user to type the object's name before the red button enables.
struct DestructiveSQLConfirmationSheet: View {
    let pending: PendingSQLExecution
    let connection: String
    let environment: ConnectionEnvironment
    let onConfirm: () -> Void
    let onCancel: () -> Void
    @State private var typed = ""
    @FocusState private var typing: Bool

    /// Typing the name is required where a mistake costs the most.
    private var requiresTypedName: Bool { environment == .production && pending.assessment.target != nil }
    private var confirmed: Bool { !requiresTypedName || typed.trimmingCharacters(in: .whitespaces) == pending.assessment.target }

    var body: some View {
        PortbaseSheet(pending.assessment.title, subtitle: connection.isEmpty ? nil : connection, onClose: onCancel) {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    HStack(alignment: .top, spacing: Spacing.m) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.tileSymbol)
                            .foregroundStyle(.red)
                            .frame(width: Sizes.iconTile, height: Sizes.iconTile)
                            .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Text(pending.assessment.message)
                                .font(.bodyText)
                                .foregroundStyle(PortSQLPalette.ink)
                                .fixedSize(horizontal: false, vertical: true)
                            if environment != .none {
                                HStack(spacing: Spacing.xs) {
                                    EnvironmentBadge(environment: environment)
                                    if environment == .production {
                                        Text("You're connected to a production database.")
                                            .font(.captionText)
                                            .foregroundStyle(PortSQLPalette.muted)
                                    }
                                }
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        PortbaseFieldLabel(L10n.text("Statement"))
                        PortbaseCodeBlock(text: pending.sql)
                    }
                    if requiresTypedName, let target = pending.assessment.target {
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            PortbaseFieldLabel(L10n.format("Type %@ to confirm", target))
                            TextField("", text: $typed)
                                .textFieldStyle(.plain)
                                .font(.codeText)
                                .autocorrectionDisabled()
                                .portbaseTextCapitalization(.never)
                                .focused($typing)
                                .portbaseFieldChrome()
                                .accessibilityLabel(L10n.format("Type %@ to confirm", target))
                        }
                    }
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, Spacing.l)
            }
        } footer: {
            Button("Cancel", action: onCancel)
                .buttonStyle(.portbaseSecondary)
                .keyboardShortcut(.cancelAction)
            Button(pending.assessment.actionTitle ?? L10n.text("Run Anyway"), role: .destructive, action: onConfirm)
                .buttonStyle(.portbaseDestructive)
                .disabled(!confirmed)
        }
        .onAppear { typing = requiresTypedName }
    }
}
