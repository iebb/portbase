import SwiftUI

struct ScriptRunProgress: Equatable {
    let current: Int
    let total: Int
}

/// The statement a script stopped at, after the statements before it succeeded.
struct FailedScriptStatement: Equatable {
    let number: Int
    let total: Int
    let sql: String
    let message: String
}

/// Names a statement's result for its tab, as DataGrip and TablePlus do: the table a query read, or
/// the change and the table it made, with the row count or rows affected beside it.
enum ResultTabLabel {
    static func title(for result: QueryResultTable, number: Int, engine: DatabaseEngine?) -> String {
        let words = SQLEditingService.codeWords(result.sourceQuery ?? "", engine: engine ?? .postgresql)
        let table = result.sourceTableReference.map(shortName)
        guard let verb = words.first else { return table ?? L10n.format("Result %d", number) }
        switch verb {
        case "SELECT", "WITH", "VALUES", "TABLE":
            return table ?? (verb == "WITH" ? "WITH" : "SELECT")
        case "EXPLAIN":
            return table.map { "EXPLAIN " + $0 } ?? "EXPLAIN"
        default:
            return table.map { verb + " " + $0 } ?? verb
        }
    }

    /// Titles for every tab, numbering repeats so two queries of one table read orders and orders (2).
    static func titles(for results: [QueryResultTable], engine: DatabaseEngine?) -> [String] {
        var seen: [String: Int] = [:]
        return results.enumerated().map { index, result in
            let title = title(for: result, number: index + 1, engine: engine)
            seen[title, default: 0] += 1
            let count = seen[title] ?? 1
            return count > 1 ? title + " (\(count))" : title
        }
    }

    static func detail(for result: QueryResultTable) -> String? {
        if let affected = result.affectedRowCount, result.columns.isEmpty { return L10n.plural("affected_count", count: affected) }
        guard !result.columns.isEmpty || !result.rows.isEmpty else { return nil }
        let rows = L10n.plural("row_count", count: result.rows.count)
        return result.isTruncated == true ? rows + "+" : rows
    }

    /// The table without its schema or quotes, so "main"."orders" reads as orders.
    static func shortName(_ reference: String) -> String {
        let last = reference.split(separator: ".").last.map(String.init) ?? reference
        return last.trimmingCharacters(in: CharacterSet(charactersIn: "\"`[]"))
    }
}

/// One tab per statement a script ran, with a failed tab where it stopped.
struct ResultSetTabs: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel

    static func isVisible(_ workspace: WorkspaceViewModel) -> Bool {
        workspace.resultSets.count > 1 || workspace.failedStatement != nil || (workspace.runProgress?.total ?? 0) > 1
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.xs) {
                    let titles = ResultTabLabel.titles(for: workspace.resultSets, engine: workspace.selectedBookmark?.engine)
                    ForEach(workspace.resultSets.indices, id: \.self) { index in
                        tab(index, title: titles[index]).id(index)
                    }
                    if let failed = workspace.failedStatement { failedTab(failed) }
                    if let progress = workspace.runProgress, progress.total > 1 {
                        HStack(spacing: Spacing.xs) {
                            ProgressView().controlSize(.small)
                            Text(L10n.format("Running %1$d of %2$d", progress.current, progress.total))
                        }
                        .font(.captionText.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Spacing.s)
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.vertical, 2)
            }
            .onChange(of: workspace.selectedResultIndex) { _, index in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(index, anchor: .center) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Result Set")
    }

    private func tab(_ index: Int, title: String) -> some View {
        let result = workspace.resultSets[index]
        let selected = index == workspace.selectedResultIndex
        let detail = ResultTabLabel.detail(for: result)
        return Button { workspace.selectResult(index) } label: {
            HStack(spacing: Spacing.xs) {
                Image(systemName: result.columns.isEmpty ? "checkmark.circle" : "tablecells")
                    .foregroundStyle(selected ? PortSQLPalette.accent : .secondary)
                Text(verbatim: title).lineLimit(1).font(.rowDetail.weight(selected ? .semibold : .regular))
                if let detail {
                    Text(verbatim: detail).font(.captionText.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.horizontal, Spacing.s)
            .frame(minHeight: Sizes.control)
            .background(selected ? PortSQLPalette.accent.opacity(0.12) : PortSQLPalette.panel, in: Capsule())
            .overlay { Capsule().strokeBorder(selected ? PortSQLPalette.accent.opacity(0.45) : PortSQLPalette.stroke) }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .contextMenu { statementMenu(result.sourceQuery) }
        .help(result.sourceQuery ?? title)
        .accessibilityLabel(L10n.format("Result %1$d of %2$d", index + 1, workspace.resultSets.count) + ", " + title + (detail.map { ", " + $0 } ?? ""))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func failedTab(_ failed: FailedScriptStatement) -> some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            Text(L10n.format("Statement %1$d of %2$d failed", failed.number, failed.total)).lineLimit(1).font(.rowDetail)
        }
        .padding(.horizontal, Spacing.s)
        .frame(minHeight: Sizes.control)
        .background(Color.red.opacity(0.1), in: Capsule())
        .overlay { Capsule().strokeBorder(Color.red.opacity(0.35)) }
        .contextMenu { statementMenu(failed.sql) }
        .help(failed.sql + "\n\n" + failed.message)
        .accessibilityElement(children: .combine)
        .accessibilityHint(failed.message)
    }

    @ViewBuilder private func statementMenu(_ sql: String?) -> some View {
        if let sql, !sql.isEmpty {
            Button("Copy Statement", systemImage: "doc.on.doc") { PortbaseClipboard.copy(sql) }
            Button("Show in Editor", systemImage: "text.cursor") { workspace.revealStatement(sql) }
        }
    }
}
