import SwiftUI

/// A readable query plan: indented steps, relative cost bars, row estimates, and warnings.
struct QueryPlanView: View {
    let plan: QueryPlan

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            facts
            VStack(alignment: .leading, spacing: 0) {
                ForEach(plan.nodes) { node in
                    if node.id > 0 { Divider().padding(.leading, QueryPlanRow.leadingInset(depth: node.depth)) }
                    QueryPlanRow(node: node, maximumCost: plan.maximumCost)
                }
            }
        }
    }

    /// Steps, warnings and total cost as one line of secondary text; only the warnings take a color.
    private var facts: some View {
        var line = Text(L10n.format("Steps: %d", plan.nodes.count)).foregroundColor(.secondary)
        if plan.warningCount > 0 {
            line = line + Text(verbatim: " · ").foregroundColor(.secondary)
                + Text(L10n.format("Warnings: %d", plan.warningCount)).foregroundColor(.orange)
        }
        if plan.maximumCost > 0 {
            line = line + Text(verbatim: " · ").foregroundColor(.secondary)
                + Text(L10n.format("Total cost: %@", plan.maximumCost.formatted(.number.precision(.fractionLength(0...2))))).foregroundColor(.secondary)
        }
        if let execution = plan.executionTime {
            line = line + Text(verbatim: " · ").foregroundColor(.secondary)
                + Text(L10n.format("Ran in %@", QueryPlanRow.milliseconds(execution))).foregroundColor(.secondary)
        }
        return line.font(.captionText.monospacedDigit())
    }
}

private struct QueryPlanRow: View {
    let node: QueryPlan.Node
    let maximumCost: Double

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            if node.depth > 0 {
                Image(systemName: "arrow.turn.down.right")
                    .font(.captionText)
                    .foregroundStyle(.tertiary)
                    .padding(.top, Spacing.xxxs)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                    Text(node.title)
                        .font(.rowTitle)
                        .foregroundStyle(PortSQLPalette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if let warning = node.warning {
                        Label(warning.title, systemImage: "exclamationmark.triangle.fill")
                            .font(.captionStrong)
                            .foregroundStyle(.orange)
                    }
                }
                ForEach(node.details, id: \.self) { detail in
                    Text(detail)
                        .font(.codeCaption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if node.totalCost != nil || node.estimatedRows != nil || node.actualRows != nil {
                    HStack(spacing: Spacing.s) {
                        if let total = node.totalCost {
                            if maximumCost > 0 {
                                GeometryReader { proxy in
                                    Capsule().fill(PortSQLPalette.sunken)
                                        .overlay(alignment: .leading) {
                                            Capsule().fill(costTint)
                                                .frame(width: max(4, proxy.size.width * CGFloat(total / maximumCost)))
                                        }
                                }
                                .frame(width: 90, height: Spacing.xs)
                                .accessibilityHidden(true)
                            }
                            Text(L10n.format("Cost %@", total.formatted(.number.precision(.fractionLength(0...2)))))
                        }
                        if let rows = node.estimatedRows {
                            Text(L10n.format("Rows ≈ %@", rows.formatted(.number.notation(.compactName))))
                        }
                        if let actual = node.actualRows, (node.loops ?? 1) > 0 {
                            // Per loop, as the database reports it, with the loop count when the step repeated.
                            let loops = node.loops ?? 1
                            Text(L10n.format("Actual %@", actual.formatted(.number.notation(.compactName))) + (loops > 1 ? " × \(Int(loops))" : ""))
                                .foregroundStyle(node.isMisestimated ? Color.orange : Color.secondary)
                            if let time = node.actualTime { Text(Self.milliseconds(time * loops)) }
                        }
                    }
                    .font(.microText.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Spacing.s)
        .padding(.trailing, Spacing.m)
        .padding(.leading, Self.leadingInset(depth: node.depth))
        .accessibilityElement(children: .combine)
    }

    static func milliseconds(_ value: Double) -> String {
        Measurement(value: value, unit: UnitDuration.milliseconds)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0...3))))
    }

    /// Each level of the plan tree indents by one step, capped so deep plans stay readable.
    static func leadingInset(depth: Int) -> CGFloat { CGFloat(min(depth, 8)) * Spacing.l + Spacing.m }

    private var costTint: Color {
        guard let total = node.totalCost, maximumCost > 0 else { return PortSQLPalette.accent }
        let share = total / maximumCost
        return share > 0.66 ? .orange : PortSQLPalette.accent
    }
}
