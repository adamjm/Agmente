import SwiftUI
import ACPClient

/// New Project for a gateway server (D-091): a name and a root. The gateway makes `<root>/<name>` and
/// registers it as a project. The name is checked here with the gateway's rules, and the gateway's own
/// text is shown when it still refuses.
struct GatewayNewProjectSheet: View {
    @StateObject private var model: GatewayNewProjectModel
    let onClose: () -> Void

    init(clientProvider: @escaping () -> GatewayClient?, connectionScheme: String = "wss", runners: [GatewayRunner] = [], defaultRunner: String? = nil, onCreated: @escaping (GatewayProject) async -> Void, onClose: @escaping () -> Void) {
        _model = StateObject(wrappedValue: GatewayNewProjectModel(clientProvider: clientProvider, connectionScheme: connectionScheme, runners: runners, defaultRunner: defaultRunner, onCreated: onCreated))
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

                if !model.runnerChoices.isEmpty {
                    Section {
                        Picker("Runner", selection: $model.selectedRunner) {
                            ForEach(model.runnerChoices, id: \.id) { runner in
                                Text(runner.name).tag(Optional(runner.id))
                            }
                        }
                        .accessibilityIdentifier("newProjectRunner")
                    } footer: {
                        Text("The agent this project runs. It is fixed once the project is made.")
                    }
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

                gitSection

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
            .task {
                await model.credentials.load()
            }
        }
    }

    /// The Git section (D-105). The toggle is off by default and disabled on a gateway without git.
    @ViewBuilder
    private var gitSection: some View {
        Section {
            Toggle("Create Git repository", isOn: $model.gitEnabled)
                .disabled(model.gitUnsupported)
                .accessibilityIdentifier("newProjectGitToggle")
            if model.gitEnabled && !model.gitUnsupported {
                TextField("Remote URL (optional)", text: $model.remoteURL)
#if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
#endif
                    .autocorrectionDisabled()
                    .accessibilityLabel("Remote URL, optional")
                    .accessibilityValue(model.remoteProblem ?? "")
                    .accessibilityIdentifier("newProjectRemoteURL")
                if let problem = model.remoteProblem {
                    Text(problem)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("newProjectRemoteProblem")
                }
                if model.remoteHost != nil {
                    NavigationLink {
                        GatewayGitCredentialPicker(model: model, credentials: model.credentials)
                    } label: {
                        LabeledContent("Credential") {
                            Text(model.selectedCredentialName)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityLabel("Credential, \(model.selectedCredentialName)")
                    .accessibilityHint("Opens the credential list")
                    .accessibilityIdentifier("newProjectCredential")
                }
            }
        } header: {
            Text("Git")
        } footer: {
            Text(gitFooter)
                .accessibilityIdentifier(model.gitUnsupported ? "newProjectGitUnsupported" : "newProjectGitFooter")
        }
    }

    private var gitFooter: String {
        if model.gitUnsupported {
            return "This gateway does not support Git yet. Update it to create a Git repository."
        }
        if let loadMessage = model.credentials.loadMessage, model.credentials.support == .unknown {
            return "Could not load Git credentials: \(loadMessage)"
        }
        guard model.gitEnabled else {
            return "Runs git init in the new folder on the gateway's computer."
        }
        if model.remoteHost != nil {
            return "Needed only for a private HTTPS remote. Stored on your Mac."
        }
        return "The repository starts with no remote."
    }
}
