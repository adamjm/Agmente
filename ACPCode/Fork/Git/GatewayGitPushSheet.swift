import SwiftUI
import ACPClient

/// "Push to remote" for a project (D-105). The person picks a stored credential, confirms, and the gateway
/// pushes the branch's commits with it. The app sends a token nowhere: it names a credential by id only.
/// Uncommitted changes are not pushed. The copy here is the app's own; the spec has none for this sheet.
struct GatewayGitPushSheet: View {
    @ObservedObject var model: GitProjectModel
    @StateObject private var credentials: GatewayGitCredentialsModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedId: String?
    @State private var confirming = false
    @State private var isPushing = false
    @State private var resultText: String?
    @State private var errorText: String?

    init(model: GitProjectModel) {
        self.model = model
        _credentials = StateObject(wrappedValue: GatewayGitCredentialsModel(clientProvider: { [weak model] in model?.gitClient() }))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if credentials.support == .unsupported {
                        Text("This gateway does not support pushing yet.")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("gitPushUnsupported")
                    } else if credentials.credentials.isEmpty {
                        Text("No Git credentials. Add one under Edit Server, then Git credentials.")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("gitPushNoCredentials")
                    }
                    ForEach(credentials.credentials) { credential in
                        credentialRow(credential)
                    }
                } header: {
                    Text("Credential")
                } footer: {
                    Text("Pushes this branch's commits to origin. Uncommitted changes are not pushed. The gateway checks that origin is on the credential's host.")
                }
                if let resultText {
                    Section {
                        Label(resultText, systemImage: "checkmark.circle")
                            .foregroundStyle(.green)
                            .accessibilityIdentifier("gitPushResult")
                    }
                }
                if let errorText {
                    Section {
                        Label(errorText, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("gitPushError")
                    }
                }
            }
            .navigationTitle("Push to remote")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("gitPushDone")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Push") { confirming = true }
                        .disabled(selectedId == nil || isPushing || credentials.support != .supported)
                        .accessibilityIdentifier("gitPushButton")
                }
            }
            .alert("Push to remote?", isPresented: $confirming) {
                Button("Cancel", role: .cancel) {}
                    .accessibilityIdentifier("gitPushCancel")
                Button("Push") { Task { await push() } }
                    .accessibilityIdentifier("gitPushConfirm")
            } message: {
                Text("This pushes the branch's commits to origin with the selected credential.")
            }
            .task { await credentials.load() }
        }
        .accessibilityIdentifier("gitPushSheet")
    }

    private func credentialRow(_ credential: GatewayGitCredential) -> some View {
        let selected = selectedId == credential.id
        return Button {
            selectedId = credential.id
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(credential.name)
                    Text(credential.host)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark").accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(credential.name), \(credential.host)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("gitPushCredential.\(credential.id)")
    }

    private func push() async {
        guard let id = selectedId, let client = model.gitClient() else {
            errorText = "Not connected to the gateway."
            return
        }
        isPushing = true
        resultText = nil
        errorText = nil
        defer { isPushing = false }
        do {
            let result = try await client.gitPush(projectId: model.projectId, credentialId: id)
            resultText = "Pushed \(result.branch) to \(result.remote)."
        } catch {
            errorText = (error as? GatewayError)?.message ?? error.localizedDescription
        }
    }
}
