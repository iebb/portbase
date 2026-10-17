import SwiftUI

struct RedisQueryEditorCard: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @State private var showsHelp = false

    private var command: RedisCommand? { try? RedisCommandService.parse(workspace.queryText) }
    private var validation: String? {
        guard !workspace.queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        do { _ = try RedisCommandService.parse(workspace.queryText); return nil }
        catch { return error.localizedDescription }
    }

    var body: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: Spacing.s) {
                HStack {
                    Text("Redis command").font(.cardTitle)
                    Spacer()
                    QueryLibraryButton()
                    if let command {
                        Text(L10n.text(command.isReadOnly ? "Read-only" : "Write"))
                            .font(.captionText).foregroundStyle(command.isReadOnly ? Color.secondary : Color.orange)
                    }
                    Button { showsHelp = true } label: {
                        Image(systemName: "questionmark.circle").frame(width: Sizes.touchTarget, height: Sizes.touchTarget)
                    }.accessibilityLabel("Redis command reference")
                }
                TextEditor(text: $workspace.queryText)
                    .font(.codeText)
                    .portbaseTextCapitalization(.never).autocorrectionDisabled()
                    .frame(minHeight: 140, maxHeight: 260)
                    .accessibilityLabel("Redis command editor")
                if let validation { Text(validation).font(.captionText).foregroundStyle(.red).textSelection(.enabled) }
                HStack(spacing: Spacing.l) {
                    Button {
                        if workspace.isRunning { workspace.cancelQuery() }
                        else { workspace.runQuery(entireBuffer: true) }
                    } label: {
                        Label(L10n.text(workspace.isRunning ? "Stop" : "Run"), systemImage: workspace.isRunning ? "stop.fill" : "play.fill")
                            .frame(minHeight: Sizes.touchTarget)
                    }
                    .buttonStyle(.portbasePrimary)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!workspace.isRunning && (command == nil || workspace.selectedBookmark == nil))
                    Button("Save", systemImage: "bookmark") { workspace.saveSnippet() }
                        .frame(minHeight: Sizes.touchTarget).disabled(command == nil)
                    Spacer()
                }
            }
        }
        .sheet(isPresented: $showsHelp) {
            PortbaseSheet(L10n.text("Redis command reference"), onClose: { showsHelp = false }) {
                List {
                    Section {
                        Text("One command per run. Quote empty values and spaces; use \\xNN for binary bytes.")
                            .font(.rowDetail)
                    }
                    ForEach(RedisCommandService.help) { item in
                        Button {
                            workspace.queryText = item.syntax
                            showsHelp = false
                        } label: {
                            VStack(alignment: .leading, spacing: Spacing.xxs) {
                                Text(verbatim: item.syntax).font(.codeDetail)
                                Text(item.summary).font(.captionText).foregroundStyle(.secondary)
                            }.frame(minHeight: Sizes.touchTarget, alignment: .leading)
                        }.buttonStyle(.plain)
                    }
                }
            } footer: {
                Button("Done") { showsHelp = false }
                    .buttonStyle(.portbasePrimary)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
