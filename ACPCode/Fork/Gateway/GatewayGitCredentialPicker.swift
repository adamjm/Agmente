import SwiftUI
import ACPClient

/// The credential list pushed from the New Project sheet (D-105). A pushed list, not a menu: it shows the
/// host and date of each profile, and "Add credential…" opens the form with the remote's host filled in.
struct GatewayGitCredentialPicker: View {
    @ObservedObject var model: GatewayNewProjectModel
    @ObservedObject var credentials: GatewayGitCredentialsModel
    @State private var adding = false

    var body: some View {
        List {
            Section {
                noneRow
            }
            if let host = model.remoteHost {
                Section {
                    ForEach(model.credentialRows) { credential in
                        credentialRow(credential)
                    }
                    if model.credentialRows.isEmpty {
                        Text("No credential for \(host) yet.")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("newProjectCredentialNoneForHost")
                    }
                } header: {
                    Text(host)
                } footer: {
                    Text("Only credentials for \(host) are listed for this remote.")
                }
            }
            Section {
                Button {
                    adding = true
                } label: {
                    Label("Add credential…", systemImage: "plus")
                }
                .disabled(!credentials.canEnterSecrets)
                .accessibilityLabel("Add credential")
                .accessibilityIdentifier("newProjectAddCredential")
            } footer: {
                if !credentials.canEnterSecrets {
                    Text(GatewayGitSecretPolicy.insecureMessage)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("newProjectCredentialInsecure")
                }
            }
        }
        .navigationTitle("Credential")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .sheet(isPresented: $adding) {
            GatewayGitCredentialForm(model: credentials, editing: nil, prefillHost: model.remoteHost ?? "") { id in
                model.selectedCredentialId = id
            }
        }
        .task { await credentials.load() }
    }

    private var noneRow: some View {
        Button {
            model.selectedCredentialId = nil
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("None")
                    Text("Public remotes only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.selectedCredentialId == nil {
                    Image(systemName: "checkmark").accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("None")
        .accessibilityAddTraits(model.selectedCredentialId == nil ? .isSelected : [])
        .accessibilityIdentifier("newProjectCredentialNone")
    }

    private func credentialRow(_ credential: GatewayGitCredential) -> some View {
        let selected = model.selectedCredentialId == credential.id
        let created = GatewayGitCredentialText.createdLabel(credential.createdAt)
        let subtitle = [credential.host, created].compactMap { $0 }.joined(separator: " · ")
        return Button {
            model.selectedCredentialId = credential.id
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(credential.name)
                    Text(subtitle)
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
        .accessibilityLabel("\(credential.name), \(subtitle)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("newProjectCredentialRow.\(credential.id)")
    }
}
