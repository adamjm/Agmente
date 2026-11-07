import SwiftUI

/// The MCP server list (FR-40, PLAN 6B.2): add, edit, enable or disable, and delete.
/// Values typed here go to the Keychain. The list itself never shows a stored value.
struct MCPServersView: View {
    @ObservedObject var model: MCPServersModel
    @State private var editing: MCPServerEntry?
    @State private var isAdding = false
    @State private var errorText: String?

    var body: some View {
        List {
            if let problem = model.loadError {
                Section {
                    Text(problem).foregroundStyle(.red)
                }
            }
            Section {
                if model.servers.isEmpty {
                    Text("No servers. Bob uses only the MCP servers in its own settings.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.servers) { entry in
                    row(for: entry)
                }
                .onDelete(perform: delete)
            } footer: {
                Text("Servers are sent when a session starts or resumes. A running session keeps its servers until it is reopened.")
            }
        }
        .navigationTitle("MCP servers")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isAdding = true
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .disabled(model.loadError != nil)
            }
        }
        .sheet(isPresented: $isAdding) {
            MCPServerEditor(model: model, entry: nil)
        }
        .sheet(item: $editing) { entry in
            MCPServerEditor(model: model, entry: entry)
        }
        .alert("Could not change the server", isPresented: Binding(
            get: { errorText != nil },
            set: { if !$0 { errorText = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
    }

    @ViewBuilder
    private func row(for entry: MCPServerEntry) -> some View {
        HStack {
            Button {
                editing = entry
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.name).font(.body)
                    Text(subtitle(for: entry))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if entry.transport == .stdio {
                        Text(MCPServerWarning.stdio)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .buttonStyle(.plain)
            Toggle("Enabled", isOn: Binding(
                get: { entry.isEnabled },
                set: { newValue in
                    do { try model.setEnabled(id: entry.id, newValue) } catch { errorText = error.localizedDescription }
                }
            ))
            .labelsHidden()
        }
    }

    private func subtitle(for entry: MCPServerEntry) -> String {
        switch entry.transport {
        case .http: return "HTTP: \(entry.url ?? "no URL")"
        case .stdio: return "Command: \(entry.command ?? "none")"
        }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            let id = model.servers[index].id
            do { try model.remove(id: id) } catch { errorText = error.localizedDescription }
        }
    }
}

/// One header or environment row in the editor. The value is typed, never shown back.
struct MCPValueRow: Identifiable, Equatable {
    var id = UUID()
    var name: String
    var value: String = ""
}

/// The editor's state. Converts to an entry and its values, and back from a stored entry.
struct MCPServerDraft: Equatable {
    var id: UUID
    var name = ""
    var transport: MCPServerEntry.Transport = .http
    var isEnabled = true
    var url = ""
    var headers: [MCPValueRow] = []
    var command = ""
    var argsText = ""
    var env: [MCPValueRow] = []
    var alwaysAllowText = ""
    var acknowledged = false

    init(entry: MCPServerEntry?) {
        guard let entry else {
            id = UUID()
            return
        }
        id = entry.id
        name = entry.name
        transport = entry.transport
        isEnabled = entry.isEnabled
        url = entry.url ?? ""
        headers = entry.headerNames.map { MCPValueRow(name: $0) }
        command = entry.command ?? ""
        argsText = entry.args.joined(separator: "\n")
        env = entry.envNames.map { MCPValueRow(name: $0) }
        alwaysAllowText = entry.alwaysAllow.joined(separator: "\n")
        acknowledged = entry.stdioAcknowledged
    }

    /// The entry, plus the values typed in this session, keyed by name.
    func build() -> (entry: MCPServerEntry, headerValues: [String: String], envValues: [String: String]) {
        let lines = { (text: String) -> [String] in
            text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        let entry = MCPServerEntry(
            id: id,
            name: name,
            transport: transport,
            isEnabled: isEnabled,
            url: transport == .http ? url.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
            headerNames: transport == .http ? headers.map { $0.name.trimmingCharacters(in: .whitespaces) } : [],
            command: transport == .stdio ? command.trimmingCharacters(in: .whitespaces) : nil,
            args: transport == .stdio ? lines(argsText) : [],
            envNames: transport == .stdio ? env.map { $0.name.trimmingCharacters(in: .whitespaces) } : [],
            alwaysAllow: lines(alwaysAllowText),
            stdioAcknowledged: transport == .stdio && acknowledged
        )
        // Duplicate names are refused by validation; this only keeps the first value so it cannot trap.
        let headerValues = Dictionary(
            headers.map { ($0.name.trimmingCharacters(in: .whitespaces), $0.value) },
            uniquingKeysWith: { first, _ in first }
        )
        let envValues = Dictionary(
            env.map { ($0.name.trimmingCharacters(in: .whitespaces), $0.value) },
            uniquingKeysWith: { first, _ in first }
        )
        return (entry.normalized(), headerValues, envValues)
    }
}

struct MCPServerEditor: View {
    @ObservedObject var model: MCPServersModel
    let isNew: Bool
    @State private var draft: MCPServerDraft
    @State private var errorText: String?
    @Environment(\.dismiss) private var dismiss

    init(model: MCPServersModel, entry: MCPServerEntry?) {
        self.model = model
        self.isNew = entry == nil
        _draft = State(initialValue: MCPServerDraft(entry: entry))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Name", text: $draft.name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Picker("Type", selection: $draft.transport) {
                        Text("HTTP").tag(MCPServerEntry.Transport.http)
                        Text("Command").tag(MCPServerEntry.Transport.stdio)
                    }
                    .pickerStyle(.segmented)
                    Toggle("Enabled", isOn: $draft.isEnabled)
                }

                if draft.transport == .http {
                    Section {
                        TextField("https://example.com/mcp", text: $draft.url)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } header: {
                        Text("Endpoint")
                    } footer: {
                        Text("https:// to any host, or http:// to localhost only.")
                    }
                    Section {
                        ForEach($draft.headers) { $row in
                            TextField("Header name", text: $row.name)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            SecureField(valuePlaceholder, text: $row.value)
                        }
                        .onDelete { draft.headers.remove(atOffsets: $0) }
                        Button("Add header") { draft.headers.append(MCPValueRow(name: "")) }
                    } header: {
                        Text("Headers")
                    } footer: {
                        Text("Header values are stored in the Keychain on this device. They are sent only when a session starts or resumes.")
                    }
                }

                if draft.transport == .stdio {
                    Section {
                        Text(MCPServerWarning.stdio)
                            .foregroundStyle(.orange)
                        Toggle("I understand this command runs in the project container", isOn: $draft.acknowledged)
                    }
                    Section("Command") {
                        TextField("Command", text: $draft.command)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Arguments, one per line", text: $draft.argsText, axis: .vertical)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    Section {
                        ForEach($draft.env) { $row in
                            TextField("Variable name", text: $row.name)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            SecureField(valuePlaceholder, text: $row.value)
                        }
                        .onDelete { draft.env.remove(atOffsets: $0) }
                        Button("Add variable") { draft.env.append(MCPValueRow(name: "")) }
                    } header: {
                        Text("Environment")
                    } footer: {
                        Text("Values are stored in the Keychain and sent to the container only.")
                    }
                }

                Section {
                    TextField("Tool names, one per line", text: $draft.alwaysAllowText, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Always allow (optional)")
                } footer: {
                    Text(MCPServerWarning.alwaysAllow)
                }
            }
            .navigationTitle(isNew ? "Add MCP server" : "Edit MCP server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
            .alert("Could not save", isPresented: Binding(
                get: { errorText != nil },
                set: { if !$0 { errorText = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorText ?? "")
            }
        }
    }

    /// An existing entry keeps its stored value when the field is left empty.
    private var valuePlaceholder: String {
        isNew ? "Value" : "Value (leave empty to keep)"
    }

    private func save() {
        let built = draft.build()
        do {
            try model.upsert(built.entry, headerValues: built.headerValues, envValues: built.envValues)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
