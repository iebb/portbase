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
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Redis command").font(.headline)
                    Spacer()
                    QueryLibraryButton()
                    if let command {
                        Text(L10n.text(command.isReadOnly ? "Read-only" : "Write"))
                            .font(.caption).foregroundStyle(command.isReadOnly ? Color.secondary : Color.orange)
                    }
                    Button { showsHelp = true } label: {
                        Image(systemName: "questionmark.circle").frame(width: 44, height: 44)
                    }.accessibilityLabel("Redis command reference")
                }
                TextEditor(text: $workspace.queryText)
                    .font(.system(.body, design: .monospaced))
                    .portbaseTextCapitalization(.never).autocorrectionDisabled()
                    .frame(minHeight: 140, maxHeight: 260)
                    .accessibilityLabel("Redis command editor")
                if let validation { Text(validation).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                HStack(spacing: 16) {
                    Button {
                        if workspace.isRunning { workspace.cancelQuery() }
                        else { workspace.runQuery(entireBuffer: true) }
                    } label: {
                        Label(L10n.text(workspace.isRunning ? "Stop" : "Run"), systemImage: workspace.isRunning ? "stop.fill" : "play.fill")
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!workspace.isRunning && (command == nil || workspace.selectedBookmark == nil))
                    Button("Save", systemImage: "bookmark") { workspace.saveSnippet() }
                        .frame(minHeight: 44).disabled(command == nil)
                    Spacer()
                }
            }
        }
        .sheet(isPresented: $showsHelp) {
            NavigationStack {
                List {
                    Section {
                        Text("One command per run. Quote empty values and spaces; use \\xNN for binary bytes.")
                            .font(.callout)
                    }
                    ForEach(RedisCommandService.help) { item in
                        Button {
                            workspace.queryText = item.syntax
                            showsHelp = false
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(verbatim: item.syntax).font(.system(.callout, design: .monospaced))
                                Text(item.summary).font(.caption).foregroundStyle(.secondary)
                            }.frame(minHeight: 44, alignment: .leading)
                        }.buttonStyle(.plain)
                    }
                }
                .navigationTitle("Redis command reference")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showsHelp = false } } }
            }
        }
    }
}
