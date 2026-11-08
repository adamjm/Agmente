import SwiftUI
import ACPClient

/// The Git credentials of one gateway (D-105): names, hosts and dates, never a token. Reached from the
/// Edit Server form. Add and Replace open a sheet; Delete asks first.
struct GatewayGitCredentialsView: View {
    @ObservedObject var model: GatewayGitCredentialsModel
    @State private var addingNew = false
    @State private var replacing: GatewayGitCredential?
    @State private var deleting: GatewayGitCredential?
    @State private var errorText: String?

    var body: some View {
        Group {
            if model.support == .unsupported {
                ContentUnavailableView("Git credentials need a newer gateway",
                                       systemImage: "key.slash",
                                       description: Text("Update the gateway to store Git credentials."))
                    .accessibilityIdentifier("gitCredentialsUnsupported")
            } else {
                list
            }
        }
        .navigationTitle("Git Credentials")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .toolbar {
            if model.support == .supported {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        addingNew = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add Git credential")
                    .accessibilityIdentifier("gitCredentialAdd")
                    .disabled(!model.canEnterSecrets || model.isBusy)
                }
            }
        }
        .sheet(isPresented: $addingNew) {
            GatewayGitCredentialForm(model: model, editing: nil, prefillHost: "") { _ in }
        }
        .sheet(item: $replacing) { credential in
            GatewayGitCredentialForm(model: model, editing: credential, prefillHost: credential.host) { _ in }
        }
        .alert("Delete “\(deleting?.name ?? "")”?", isPresented: Binding(
            get: { deleting != nil },
            set: { if !$0 { deleting = nil } }
        ), presenting: deleting) { credential in
            Button("Cancel", role: .cancel) { deleting = nil }
                .accessibilityIdentifier("gitCredentialDeleteCancel")
            Button("Delete", role: .destructive) {
                deleting = nil
                Task { errorText = await model.delete(credential) }
            }
            .accessibilityIdentifier("gitCredentialDeleteConfirm")
        } message: { _ in
            Text("This removes the secret from your Mac. Repositories already set up keep their remote, but fetches that need this credential will fail until you add one again. This can't be undone.")
        }
        .task { await model.load() }
    }

    @ViewBuilder
    private var list: some View {
        List {
            Section {
                ForEach(model.credentials) { credential in
                    row(credential)
                }
                if let errorText {
                    Label(errorText, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("gitCredentialsError")
                }
                if let loadMessage = model.loadMessage {
                    Label(loadMessage, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("gitCredentialsLoadError")
                }
            } header: {
                Text("Saved on your Mac")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("ACPCode sends each secret to your Mac once and cannot read it back, so a saved secret is never shown again.")
                    if !model.canEnterSecrets {
                        Text(GatewayGitSecretPolicy.insecureMessage)
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("gitCredentialsInsecure")
                    }
                }
            }
        }
        .overlay {
            if model.support == .supported, model.credentials.isEmpty, model.loadMessage == nil {
                ContentUnavailableView("No Git credentials",
                                       systemImage: "key",
                                       description: Text("Add one for a private repository on HTTPS. Public repositories don't need one."))
                    .accessibilityIdentifier("gitCredentialsEmpty")
            }
        }
    }

    private func row(_ credential: GatewayGitCredential) -> some View {
        let created = GatewayGitCredentialText.createdLabel(credential.createdAt)
        let stored = credential.hasSecret ? "Stored on the Mac" : "No secret stored"
        let subtitle = [stored, created].compactMap { $0 }.joined(separator: " · ")
        return Button {
            replacing = credential
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(credential.name).font(.body.weight(.semibold))
                Text(credential.host).font(.subheadline).foregroundStyle(.secondary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel("\(credential.name), \(credential.host), \(subtitle)")
        .accessibilityHint("Opens the replace form")
        .accessibilityAction(named: "Replace") { replacing = credential }
        .accessibilityAction(named: "Delete") { deleting = credential }
        .accessibilityIdentifier("gitCredential.\(credential.id)")
#if os(iOS)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                deleting = credential
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .accessibilityIdentifier("gitCredentialDelete.\(credential.id)")
        }
#endif
        .contextMenu {
            Button {
                replacing = credential
            } label: {
                Label("Replace", systemImage: "arrow.triangle.2.circlepath")
            }
            Button(role: .destructive) {
                deleting = credential
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

/// Add or Replace a credential (D-105). The token is a `SecureField`, never echoed, cleared from this view as
/// soon as it is sent, and never stored. A replacement keeps its name's profile and host.
struct GatewayGitCredentialForm: View {
    @ObservedObject var model: GatewayGitCredentialsModel
    let editing: GatewayGitCredential?
    let onSaved: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var host: String
    @State private var token: String = ""
    @State private var errorText: String?
    @State private var confirmDiscard = false

    init(model: GatewayGitCredentialsModel, editing: GatewayGitCredential?, prefillHost: String, onSaved: @escaping (String) -> Void) {
        self.model = model
        self.editing = editing
        self.onSaved = onSaved
        _name = State(initialValue: editing?.name ?? "")
        _host = State(initialValue: editing?.host ?? prefillHost)
    }

    private var isReplacing: Bool { editing != nil }

    private var nameProblem: String? {
        GatewayGitCredentialRules.nameProblem(name, existing: model.credentials, replacing: editing?.id)
    }

    private var hostProblem: String? {
        isReplacing ? nil : GatewayGitCredentialRules.hostProblem(host)
    }

    private var canSave: Bool {
        !model.isBusy && model.canEnterSecrets
            && !name.trimmingCharacters(in: .whitespaces).isEmpty && nameProblem == nil
            && hostProblem == nil && !host.isEmpty
            && GatewayGitCredentialRules.tokenProblem(token) == nil
    }

    var body: some View {
        NavigationStack {
            Form {
                if !model.canEnterSecrets {
                    Section {
                        Label(GatewayGitSecretPolicy.insecureMessage, systemImage: "lock.slash")
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("gitCredentialInsecure")
                    }
                }
                Section {
                    TextField("Name", text: $name)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("gitCredentialName")
                    if !name.isEmpty, let problem = nameProblem {
                        Text(problem).font(.footnote).foregroundStyle(.red)
                            .accessibilityIdentifier("gitCredentialNameProblem")
                    }
                } header: {
                    Text("Name")
                }
                Section {
                    TextField("Host, such as github.com", text: $host)
                        .disabled(isReplacing)
#if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
#endif
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("gitCredentialHost")
                    if !isReplacing, !host.isEmpty, let problem = hostProblem {
                        Text(problem).font(.footnote).foregroundStyle(.red)
                            .accessibilityIdentifier("gitCredentialHostProblem")
                    }
                } header: {
                    Text("Host")
                } footer: {
                    if isReplacing {
                        Text("The host stays the same. Delete the credential and add it again to change the host.")
                    }
                }
                Section {
                    SecureField("Token or password", text: $token)
#if os(iOS)
                        .textInputAutocapitalization(.never)
#endif
                        .autocorrectionDisabled()
                        .privacySensitive()
                        .disabled(!model.canEnterSecrets)
                        .accessibilityHint("Write only. It cannot be shown after saving.")
                        .accessibilityIdentifier("gitCredentialSecret")
                } header: {
                    Text("Token or password")
                } footer: {
                    Text(isReplacing
                         ? "The old secret is deleted when the new one is saved. ACPCode sends this secret to your Mac once and cannot read it back."
                         : "ACPCode sends this secret to your Mac once and cannot read it back, so it is never shown again.")
                }
                if let errorText {
                    Section {
                        Label(errorText, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("gitCredentialError")
                    }
                }
            }
            .navigationTitle(isReplacing ? "Replace Credential" : "New Credential")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { requestClose() }
                        .disabled(model.isBusy)
                        .accessibilityIdentifier("gitCredentialCancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isReplacing ? "Replace" : "Save") { save() }
                        .disabled(!canSave)
                        .accessibilityLabel(isReplacing ? "Replace credential" : "Save credential")
                        .accessibilityIdentifier("gitCredentialSave")
                }
            }
            .confirmationDialog("Discard this credential?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard", role: .destructive) {
                    token = ""
                    dismiss()
                }
                Button("Keep editing", role: .cancel) {}
            }
        }
        .interactiveDismissDisabled(!token.isEmpty || model.isBusy)
    }

    private func requestClose() {
        if token.isEmpty { dismiss() } else { confirmDiscard = true }
    }

    private func save() {
        // The view's copy is cleared before the call, so it is gone whatever the answer is.
        let secret = token
        token = ""
        let sentHost = editing?.host ?? host
        Task {
            let outcome = await model.save(id: editing?.id, name: name, host: sentHost, token: secret)
            switch outcome {
            case .saved(let id):
                onSaved(id)
                dismiss()
            case .refused(let message), .failed(let message):
                errorText = message
            }
        }
    }
}

