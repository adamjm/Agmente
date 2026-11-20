import Foundation
import ACP

/// Keeps on this device the models, modes and config options that the agent returned for a session.
///
/// A gateway session that is opened after a relaunch gets no `session/new` answer, so without this the model,
/// mode and config controls are missing. The record is the raw answer. It is changed in place when the person
/// picks a value, and it is read by the same parser as a live answer. The store is per device and per server, so
/// it never reaches the gateway or another device (plan answer Q1: keep them in the app).
enum SessionControlStore {
    /// The parts of a session answer the controls are built from. Nothing else in the answer is kept.
    static let keys = ["models", "modes", "configOptions"]
    /// Sessions kept per server. The oldest record is dropped first.
    static let maxSessionsPerServer = 100

    private struct Entry: Codable {
        var savedAt: Date
        var state: ACP.Value
    }

    private static func defaultsKey(_ serverId: UUID) -> String {
        "acpcode.sessionControls.v1.\(serverId.uuidString)"
    }

    /// Stores the controls from a session's answer. An answer with none of the keys stores nothing.
    static func save(_ answer: ACP.Value?, serverId: UUID, sessionId: String, now: Date = Date()) {
        guard !sessionId.isEmpty, let object = answer?.objectValue else { return }
        var state: [String: ACP.Value] = [:]
        for key in keys {
            if let value = object[key] { state[key] = value }
        }
        guard !state.isEmpty else { return }
        write(serverId: serverId) { entries in
            entries[sessionId] = Entry(savedAt: now, state: .object(state))
        }
    }

    /// The stored answer for a session, in the shape the parser reads, or nil.
    static func state(serverId: UUID, sessionId: String) -> ACP.Value? {
        read(serverId: serverId)[sessionId]?.state
    }

    /// Changes the stored answer of a session in place. Used when the person picks a model, mode or config value
    /// and the agent accepts it. Does nothing when the session has no record.
    static func update(serverId: UUID, sessionId: String, _ change: (inout [String: ACP.Value]) -> Void) {
        write(serverId: serverId) { entries in
            guard var entry = entries[sessionId], case .object(var object) = entry.state else { return }
            change(&object)
            entry.state = .object(object)
            entries[sessionId] = entry
        }
    }

    /// Removes a session's record, for example when the session is deleted.
    static func remove(serverId: UUID, sessionId: String) {
        write(serverId: serverId) { entries in
            entries.removeValue(forKey: sessionId)
        }
    }

    // MARK: - Storage

    private static func read(serverId: UUID) -> [String: Entry] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey(serverId)) else { return [:] }
        // A record that does not decode is treated as absent, so it never blocks the session from opening.
        return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }

    private static func write(serverId: UUID, _ mutate: (inout [String: Entry]) -> Void) {
        var entries = read(serverId: serverId)
        mutate(&entries)
        if entries.count > maxSessionsPerServer {
            let keep = entries.sorted { $0.value.savedAt > $1.value.savedAt }.prefix(maxSessionsPerServer)
            entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey(serverId))
    }
}

/// Changes the current selections in a stored answer. Pure, so the rules can be unit tested.
enum SessionControlPatch {
    static func setModel(_ modelId: String, in answer: inout [String: ACP.Value]) {
        patchObject(&answer, key: "models") { $0["currentModelId"] = .string(modelId) }
    }

    static func setMode(_ modeId: String, in answer: inout [String: ACP.Value]) {
        patchObject(&answer, key: "modes") { $0["currentModeId"] = .string(modeId) }
    }

    /// Sets `currentValue` of the config option with `configId`. Other options are left as they are.
    static func setConfigValue(_ value: ACP.Value, configId: String, in answer: inout [String: ACP.Value]) {
        guard case .array(var options)? = answer["configOptions"] else { return }
        options = options.map { option in
            guard case .object(var item) = option, item["id"]?.stringValue == configId else { return option }
            item["currentValue"] = value
            return .object(item)
        }
        answer["configOptions"] = .array(options)
    }

    private static func patchObject(
        _ answer: inout [String: ACP.Value],
        key: String,
        _ change: (inout [String: ACP.Value]) -> Void
    ) {
        guard case .object(var object)? = answer[key] else { return }
        change(&object)
        answer[key] = .object(object)
    }
}
