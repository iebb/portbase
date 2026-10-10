import Foundation

/// Aggregates of recorded console executions for dashboards.
struct WorkspaceActivity: Equatable {
    struct Day: Identifiable, Equatable {
        var id: Date { date }
        let date: Date
        let succeeded: Int
        let failed: Int
        let cancelled: Int
        var total: Int { succeeded + failed + cancelled }
    }

    let days: [Day]
    let executionCount: Int
    let successRate: Double?
    let medianDuration: TimeInterval?
    let busiestConnection: String?

    var hasActivity: Bool { executionCount > 0 }
}

enum WorkspaceActivityService {
    static func activity(
        history: [QueryHistoryEntry],
        days dayCount: Int = 14,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> WorkspaceActivity {
        let today = calendar.startOfDay(for: now)
        guard dayCount > 0, let first = calendar.date(byAdding: .day, value: -(dayCount - 1), to: today) else {
            return WorkspaceActivity(days: [], executionCount: 0, successRate: nil, medianDuration: nil, busiestConnection: nil)
        }
        let recent = history.filter { $0.executedAt >= first && $0.executedAt <= now }
        let grouped = Dictionary(grouping: recent) { calendar.startOfDay(for: $0.executedAt) }
        let days = (0..<dayCount).compactMap { offset -> WorkspaceActivity.Day? in
            guard let date = calendar.date(byAdding: .day, value: offset, to: first) else { return nil }
            let entries = grouped[date] ?? []
            return WorkspaceActivity.Day(
                date: date,
                succeeded: entries.filter { ($0.outcome ?? .succeeded) == .succeeded }.count,
                failed: entries.filter { $0.outcome == .failed }.count,
                cancelled: entries.filter { $0.outcome == .cancelled }.count
            )
        }

        let finished = recent.filter { $0.outcome != .cancelled }
        let successRate = finished.isEmpty ? nil : Double(finished.filter { ($0.outcome ?? .succeeded) == .succeeded }.count) / Double(finished.count)
        let durations = recent.compactMap(\.duration).sorted()
        let median: TimeInterval?
        if durations.isEmpty { median = nil }
        else if durations.count.isMultiple(of: 2) { median = (durations[durations.count / 2 - 1] + durations[durations.count / 2]) / 2 }
        else { median = durations[durations.count / 2] }
        let busiest = Dictionary(grouping: recent.filter { !$0.connectionName.isEmpty }, by: \.connectionName)
            .max { $0.value.count == $1.value.count ? $0.key > $1.key : $0.value.count < $1.value.count }?.key

        return WorkspaceActivity(days: days, executionCount: recent.count, successRate: successRate,
                                 medianDuration: median, busiestConnection: busiest)
    }

    /// A compact duration such as "84 ms" or "2.4 s".
    static func durationLabel(_ duration: TimeInterval, locale: Locale = .current) -> String {
        if duration < 1 {
            return Measurement(value: (duration * 1000).rounded(), unit: UnitDuration.milliseconds)
                .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0))).locale(locale))
        }
        if duration < 60 {
            return Measurement(value: duration, unit: UnitDuration.seconds)
                .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(1))).locale(locale))
        }
        return Duration.seconds(Int(duration)).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
    }
}
