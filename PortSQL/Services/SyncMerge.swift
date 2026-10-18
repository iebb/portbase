import Foundation

/// Field-level merging for synced JSON documents, so edits two devices make to different fields of the
/// same item both survive. Each field carries the date it last changed; when both sides changed a field,
/// the later change wins, and equal dates fall back to comparing the values so every device agrees.
///
/// Arrays of objects with an "id", such as a settings document's providers, merge element by element,
/// with the order as a field of its own. A removed field or element keeps its date as a tombstone, so a
/// device that hasn't seen the removal can't bring it back.
enum JSONFieldMerge {
    typealias Object = [String: Any]

    private static let orderSuffix = "#order"

    /// The document's fields by path: each top-level key, or `key[id]` for each element of an id array
    /// plus `key#order` for its order.
    static func fields(of object: Object, excluding excluded: Set<String> = []) -> [String: Any] {
        var fields: [String: Any] = [:]
        for (key, value) in object where !excluded.contains(key) {
            if let elements = identifiedElements(value) {
                for (id, element) in elements { fields[key + "[" + id + "]"] = element }
                fields[key + orderSuffix] = elements.map(\.0)
            } else {
                fields[key] = value
            }
        }
        return fields
    }

    /// Dates for a new version of a document: changed, added, and removed fields get `now`; unchanged
    /// ones keep their date, or `base` when they had none.
    static func stamp(previous: Object?, current: Object, dates: [String: Date], base: Date, now: Date,
                      excluding excluded: Set<String> = []) -> [String: Date] {
        let old = previous.map { fields(of: $0, excluding: excluded) } ?? [:]
        let new = fields(of: current, excluding: excluded)
        var stamped = dates
        for path in Set(old.keys).union(new.keys) {
            if let before = old[path], let after = new[path], equal(before, after) {
                if stamped[path] == nil { stamped[path] = base }
            } else if previous == nil {
                stamped[path] = stamped[path] ?? base
            } else {
                stamped[path] = now
            }
        }
        return stamped
    }

    /// Merges two versions of a document. Each side's missing dates count as its `base`. Returns the
    /// merged document and its field dates.
    static func merge(local: Object, localDates: [String: Date], localBase: Date,
                      remote: Object, remoteDates: [String: Date], remoteBase: Date,
                      excluding excluded: Set<String> = []) -> (Object, [String: Date]) {
        let localFields = fields(of: local, excluding: excluded)
        let remoteFields = fields(of: remote, excluding: excluded)
        let paths = Set(localFields.keys).union(remoteFields.keys).union(localDates.keys).union(remoteDates.keys)
        var merged: [String: Any] = [:]
        var dates: [String: Date] = [:]
        for path in paths {
            let localDate = localDates[path] ?? localBase
            let remoteDate = remoteDates[path] ?? remoteBase
            // A side that dates its fields and has neither the field nor a date for it never saw the field,
            // such as an entry the other side added; it doesn't compete. Without dates (earlier versions),
            // a side is a whole snapshot, and a missing field counts as removed at its date.
            let localNeverSaw = !localDates.isEmpty && localFields[path] == nil && localDates[path] == nil
            let remoteNeverSaw = !remoteDates.isEmpty && remoteFields[path] == nil && remoteDates[path] == nil
            let takesRemote: Bool
            if localNeverSaw != remoteNeverSaw {
                takesRemote = localNeverSaw
            } else if remoteDate != localDate {
                takesRemote = remoteDate > localDate
            } else {
                takesRemote = precedes(remoteFields[path], localFields[path])
            }
            dates[path] = localNeverSaw ? remoteDate : remoteNeverSaw ? localDate : max(localDate, remoteDate)
            if let value = takesRemote ? remoteFields[path] : localFields[path] { merged[path] = value }
        }
        // Fields excluded from merging, such as revision stamps, come from the newer side.
        var object = (remoteBase > localBase ? remote : local).filter { excluded.contains($0.key) }
        object.merge(assemble(merged)) { _, new in new }
        return (object, dates)
    }

    /// Rebuilds a document from its fields, putting id-array elements back in their merged order.
    private static func assemble(_ fields: [String: Any]) -> Object {
        var object: Object = [:]
        var arrays: [String: [String: Any]] = [:]
        var orders: [String: [String]] = [:]
        for (path, value) in fields {
            if path.hasSuffix(orderSuffix) {
                orders[String(path.dropLast(orderSuffix.count))] = value as? [String] ?? []
            } else if path.hasSuffix("]"), let open = path.firstIndex(of: "[") {
                let key = String(path[..<open])
                let id = String(path[path.index(after: open)..<path.index(before: path.endIndex)])
                arrays[key, default: [:]][id] = value
            } else {
                object[path] = value
            }
        }
        for key in Set(arrays.keys).union(orders.keys) {
            let elements = arrays[key] ?? [:]
            let ordered = (orders[key] ?? []).filter { elements[$0] != nil }
            let rest = elements.keys.filter { !ordered.contains($0) }.sorted()
            object[key] = (ordered + rest).compactMap { elements[$0] }
        }
        return object
    }

    /// The elements of a non-empty array whose items are all objects with a unique string or number id.
    private static func identifiedElements(_ value: Any) -> [(String, Any)]? {
        guard let array = value as? [Any], !array.isEmpty else { return nil }
        var seen = Set<String>()
        var elements: [(String, Any)] = []
        for element in array {
            guard let object = element as? Object, let id = identifier(object["id"]), seen.insert(id).inserted else { return nil }
            elements.append((id, element))
        }
        return elements
    }

    private static func identifier(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    static func equal(_ lhs: Any, _ rhs: Any) -> Bool {
        canonical(lhs) == canonical(rhs)
    }

    /// Whether `lhs` wins a tie over `rhs`: a removal wins, then the smaller encoding.
    private static func precedes(_ lhs: Any?, _ rhs: Any?) -> Bool {
        guard let lhs else { return rhs != nil }
        guard let rhs else { return false }
        return canonical(lhs).lexicographicallyPrecedes(canonical(rhs))
    }

    private static func canonical(_ value: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["v": value], options: [.sortedKeys, .fragmentsAllowed])) ?? Data()
    }

    // MARK: Codable values

    static func object<Value: Encodable>(_ value: Value) -> Object? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? Object
    }

    static func value<Value: Decodable>(_ type: Value.Type, from object: Object) -> Value? {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

/// A synced secret or pin in one version: its value, or nil once cleared, and when and where it changed.
struct SyncedVersion: Codable, Equatable {
    var value: String?
    var modified: Date
    var device: String
    var deviceName: String?
}

/// How one device's copy and the iCloud copy of a synced value come back into agreement. `base` is the
/// iCloud version this device last agreed with, which tells a change on one side from changes on both.
enum SyncResolution: Equatable {
    /// Both sides already agree.
    case inSync
    /// Only this device changed: send its copy.
    case upload
    /// Only another device changed, or this device has nothing: take the iCloud copy.
    case adopt
    /// Both changed since they last agreed, to different values.
    case conflict

    static func resolve(local: SyncedVersion?, remote: SyncedVersion?, base: Date?) -> SyncResolution {
        guard let remote else { return local?.value == nil ? .inSync : .upload }
        guard let local else { return .adopt }
        if local.value == remote.value { return .inSync }
        let remoteChanged = base.map { remote.modified != $0 } ?? true
        let localChanged = base.map { local.modified > $0 } ?? true
        switch (localChanged, remoteChanged) {
        case (false, _): return .adopt
        case (true, false): return .upload
        case (true, true): return .conflict
        }
    }

    /// Of two conflicting versions, the later one; equal dates go to the device that sorts first.
    static func winner(_ local: SyncedVersion, _ remote: SyncedVersion) -> SyncedVersion {
        if local.modified != remote.modified { return local.modified > remote.modified ? local : remote }
        return local.device < remote.device ? local : remote
    }
}
