import SwiftUI

/// The project's skills (FR-43, PLAN 6B.3): list, open to overwrite, and delete.
struct SkillsListView: View {
    @ObservedObject var model: SkillsModel
    @State private var isAdding = false
    @State private var pendingDelete: SkillSummary?

    var body: some View {
        List {
            if let message = model.message {
                Section {
                    Text(message).foregroundStyle(.red)
                }
            }
            Section {
                if model.skills.isEmpty && !model.isLoading {
                    Text("No skills in this project.").foregroundStyle(.secondary)
                }
                ForEach(model.skills) { skill in
                    NavigationLink {
                        SkillEditorView(model: model, existingName: skill.name)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(skill.name).font(.body.monospaced())
                            Text("\(skill.bytes) bytes").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            pendingDelete = skill
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            } footer: {
                Text("Skills are saved in this project's .bob/skills folder. Saving asks for Face ID.")
            }
        }
        .navigationTitle("Skills")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isAdding = true
                } label: {
                    Label("New skill", systemImage: "plus")
                }
            }
        }
        .navigationDestination(isPresented: $isAdding) {
            SkillEditorView(model: model, existingName: nil)
        }
        .refreshable { await model.refresh() }
        .task { await model.refresh() }
        .confirmationDialog(
            "Delete this skill?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete \(pendingDelete?.name ?? "skill")", role: .destructive) {
                if let name = pendingDelete?.name {
                    Task { await model.delete(name: name) }
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("The skill's folder is removed from the project. This cannot be undone.")
        }
    }
}

/// Writes one skill. Saving runs the name and size checks, then Face ID, then one request.
struct SkillEditorView: View {
    @ObservedObject var model: SkillsModel
    /// The skill being overwritten, or nil for a new one.
    let existingName: String?
    @State private var name: String
    @State private var content = ""
    @State private var isSaving = false
    @Environment(\.dismiss) private var dismiss

    init(model: SkillsModel, existingName: String?) {
        self.model = model
        self.existingName = existingName
        _name = State(initialValue: existingName ?? "")
    }

    private var contentBytes: Int { content.utf8.count }
    private var contentTooLarge: Bool { !SkillRules.isValidContent(content) }

    var body: some View {
        Form {
            Section {
                TextField("skill-name", text: $name)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(existingName != nil)
            } header: {
                Text("Name")
            } footer: {
                Text("Lowercase letters, digits and single hyphens, at most 64 characters.")
            }

            Section {
                TextEditor(text: $content)
                    .font(.body.monospaced())
                    .frame(minHeight: 260)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("SKILL.md")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(contentBytes) of \(SkillRules.maxContentBytes) bytes")
                        .foregroundStyle(contentTooLarge ? .red : .secondary)
                    if existingName != nil {
                        Text("The gateway does not return a skill's content. Enter the full new content to overwrite it.")
                    }
                }
            }

            if let message = model.message {
                Section {
                    Text(message).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(existingName ?? "New skill")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    save()
                } label: {
                    if isSaving {
                        ProgressView()
                    } else {
                        Text("Save")
                    }
                }
                .disabled(isSaving || name.isEmpty || contentTooLarge)
            }
        }
    }

    private func save() {
        isSaving = true
        Task {
            let outcome = await model.save(name: name, content: content)
            isSaving = false
            if outcome == .saved { dismiss() }
        }
    }
}
