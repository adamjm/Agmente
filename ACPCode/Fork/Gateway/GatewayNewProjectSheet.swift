import SwiftUI
import ACPClient

/// New Project for a gateway server (D-091): a name and a root. The gateway makes `<root>/<name>` and
/// registers it as a project. The name is checked here with the gateway's rules, and the gateway's own
/// text is shown when it still refuses.
struct GatewayNewProjectSheet: View {
    @StateObject private var model: GatewayNewProjectModel
    let onClose: () -> Void

    init(clientProvider: @escaping () -> GatewayClient?, onCreated: @escaping (GatewayProject) async -> Void, onClose: @escaping () -> Void) {
        _model = StateObject(wrappedValue: GatewayNewProjectModel(clientProvider: clientProvider, onCreated: onCreated))
        self.onClose = onClose
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Folder name", text: $model.name)
                        .autocorrectionDisabled()
#if os(iOS)
                        .textInputAutocapitalization(.never)
#endif
                        .accessibilityIdentifier("newProjectName")
                    if let problem = model.nameProblem {
                        Text(problem)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("newProjectNameProblem")
                    }
                } header: {
                    Text("Name")
                } footer: {
                    Text("Letters, digits, spaces, dots, hyphens and underscores. Up to 64 characters. The project takes the same name.")
                }

                Section {
                    if model.roots.count > 1 {
                        Picker("Root", selection: $model.selectedRoot) {
                            ForEach(model.roots, id: \.self) { root in
                                Text(root).tag(Optional(root))
                            }
                        }
                        .accessibilityIdentifier("newProjectRoot")
                    } else if let root = model.roots.first {
                        Text(root)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("newProjectRoot")
                    }
                    if model.isLoadingRoots {
                        ProgressView()
                    }
                    if let preview = model.folderPreview, model.canCreate {
                        Text(preview)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .accessibilityIdentifier("newProjectPath")
                    }
                    if let message = model.rootsMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("newProjectRootsMessage")
                    }
                } header: {
                    Text("Location")
                } footer: {
                    Text("The folder is created inside this root on the gateway's computer.")
                }

                if let message = model.createMessage {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("newProjectError")
                    }
                }
            }
            .navigationTitle("New Project")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onClose)
                        .disabled(model.isCreating)
                        .accessibilityIdentifier("newProjectCancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            if await model.create() {
                                onClose()
                            }
                        }
                    } label: {
                        if model.isCreating {
                            ProgressView()
                        } else {
                            Text("Create")
                        }
                    }
                    .disabled(!model.canCreate)
                    .accessibilityIdentifier("newProjectCreate")
                }
            }
            .task {
                await model.loadRoots()
            }
        }
    }
}
