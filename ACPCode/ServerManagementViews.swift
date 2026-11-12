import SwiftUI
import ACPClient
import Security
import UniformTypeIdentifiers

struct AddServerView: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: Field?
    @State private var name: String = ""
    @State private var scheme: String = "wss"
    @State private var localOnly: Bool = false
    @State private var spkiPins: String = ""
    @State private var clientIdentity: SecIdentity?
    @State private var clientIdentityChanged = false
    @State private var showIdentityImporter = false
    @State private var pendingP12: Data?
    @State private var p12Passphrase = ""
    @State private var showPassphrasePrompt = false
    @State private var host: String = ""
    @State private var token: String = ""
    @State private var cfAccessClientId: String = ""
    @State private var cfAccessClientSecret: String = ""
    @State private var workingDirectory: String = ""
    @State private var serverType: ServerType = .acp
    @State private var showCloudflareAccess: Bool = false
    @State private var isSaving = false
    @State private var isNormalizingHost = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var pendingValidation: ValidatedServerConfiguration?
    @State private var showingSummaryOverlay = false
    @State private var hasAttemptedSave = false

    let editingServer: ACPServerConfiguration?
    let initialServerType: ServerType?
    let onValidate: (String, String, String, String, String, String, String, ServerType, ServerSecurityInput) async -> Result<ValidatedServerConfiguration, Error>
    let onInsert: (ValidatedServerConfiguration) -> Void
    /// Git credentials (D-105): shown in the Edit form only when the gateway is connected and this is its server.
    private let showsGitCredentials: Bool
    @StateObject private var gitCredentials: GatewayGitCredentialsModel

    init(
        editingServer: ACPServerConfiguration? = nil,
        initialServerType: ServerType? = nil,
        onValidate: @escaping (String, String, String, String, String, String, String, ServerType, ServerSecurityInput) async -> Result<ValidatedServerConfiguration, Error>,
        onInsert: @escaping (ValidatedServerConfiguration) -> Void,
        gitCredentialsClient: (() -> GatewayClient?)? = nil,
        gitCredentialsScheme: String = "wss"
    ) {
        self.editingServer = editingServer
        self.initialServerType = initialServerType
        self.onValidate = onValidate
        self.onInsert = onInsert
        self.showsGitCredentials = editingServer != nil && gitCredentialsClient != nil
        _gitCredentials = StateObject(wrappedValue: GatewayGitCredentialsModel(
            clientProvider: gitCredentialsClient ?? { nil },
            connectionScheme: gitCredentialsScheme
        ))

        _name = State(initialValue: editingServer?.name ?? "")
        _scheme = State(initialValue: editingServer?.scheme ?? "wss")
        _localOnly = State(initialValue: editingServer?.localOnly ?? false)
        _spkiPins = State(initialValue: editingServer?.spkiPins ?? "")
        _clientIdentity = State(initialValue: editingServer.flatMap { ClientIdentityStore.shared.load(serverId: $0.id) })
        _host = State(initialValue: editingServer?.host ?? "")
        _token = State(initialValue: editingServer?.token ?? "")
        _cfAccessClientId = State(initialValue: editingServer?.cfAccessClientId ?? "")
        _cfAccessClientSecret = State(initialValue: editingServer?.cfAccessClientSecret ?? "")
        _workingDirectory = State(initialValue: editingServer?.workingDirectory ?? "")
        _serverType = State(initialValue: editingServer?.serverType ?? initialServerType ?? .acp)
        _showCloudflareAccess = State(initialValue: !(editingServer?.cfAccessClientId ?? "").isEmpty)
    }

    private enum Field: Hashable {
        case name
        case host
        case token
        case cfAccessClientId
        case cfAccessClientSecret
        case workingDirectory
    }

    @ViewBuilder
    private var serverFormContainer: some View {
#if os(macOS)
        ScrollView {
            Form {
                formSections
            }
            .formStyle(.grouped)
            .frame(maxWidth: 720)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
#else
        Form {
            formSections
        }
#endif
    }

    @ViewBuilder
    private var formSections: some View {
        Section {
            TextField("Display name", text: $name)
                .focused($focusedField, equals: .name)
                .accessibilityIdentifier("ServerNameField")
        }

        Section {
            Picker("Server Type", selection: $serverType) {
                Text("ACP")
                    .tag(ServerType.acp)
                    .accessibilityIdentifier("ServerTypeACP")
                    .accessibilityLabel("ACP")
                Text("Codex")
                    .tag(ServerType.codexAppServer)
                    .accessibilityIdentifier("ServerTypeCodex")
                    .accessibilityLabel("Codex App Server")
            }
            .accessibilityIdentifier("ServerTypePicker")
        } footer: {
            Text(serverType.description)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }

        Section {
            Toggle("Local only", isOn: $localOnly)
                .accessibilityIdentifier("LocalOnlyToggle")
                .onChange(of: localOnly) { newValue in
                    if !newValue && !Self.plaintextOffered(localOnly: false) { scheme = "wss" }
                }

            Picker("Protocol", selection: $scheme) {
                if Self.plaintextOffered(localOnly: localOnly) || scheme == "ws" {
                    Text("ws").tag("ws")
                }
                Text("wss").tag("wss")
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("ProtocolPicker")

            if localOnly {
                Text("Local only: this server can reach only this device and your local network. With ws://, the token is sent unencrypted on that network.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("LocalOnlyWarning")
            }

            TextField("Host", text: $host)
#if os(iOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
#endif
                .disableAutocorrection(true)
                .onChange(of: host, perform: normalizeHostInput)
                .focused($focusedField, equals: .host)
                .accessibilityIdentifier("HostField")

            SecureField("Bearer token (optional)", text: $token)
#if os(iOS)
                .textInputAutocapitalization(.never)
#endif
                .disableAutocorrection(true)
                .focused($focusedField, equals: .token)
        }

        Section {
            TextField("Certificate pins (optional)", text: $spkiPins, axis: .vertical)
#if os(iOS)
                .textInputAutocapitalization(.never)
#endif
                .disableAutocorrection(true)
                .font(.footnote.monospaced())
                .accessibilityIdentifier("SPKIPinsField")
            if let clientIdentity {
                HStack {
                    Label(ClientIdentityStore.summary(of: clientIdentity), systemImage: "person.badge.key")
                    Spacer()
                    Button("Remove", role: .destructive) {
                        self.clientIdentity = nil
                        clientIdentityChanged = true
                    }
                    .accessibilityIdentifier("RemoveClientCertificateButton")
                }
            } else {
                Button("Import client certificate (.p12)") { showIdentityImporter = true }
                    .accessibilityIdentifier("ImportClientCertificateButton")
            }
        } header: {
            Text("Security")
        } footer: {
            Text("Pins: base64 SHA-256 of a certificate's public key, one per line. A pin is checked in addition to normal certificate trust. The client certificate is stored in the Keychain on this device only; its passphrase is not stored.")
        }
        .fileImporter(isPresented: $showIdentityImporter, allowedContentTypes: [.pkcs12]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                errorMessage = "The certificate file could not be read."
                showError = true
                return
            }
            pendingP12 = data
            p12Passphrase = ""
            showPassphrasePrompt = true
        }
        .alert("Certificate passphrase", isPresented: $showPassphrasePrompt) {
            SecureField("Passphrase", text: $p12Passphrase)
            Button("Import") { importPendingIdentity() }
            Button("Cancel", role: .cancel) { pendingP12 = nil; p12Passphrase = "" }
        }

        Section {
            TextField("Working directory", text: $workingDirectory)
#if os(iOS)
                .textInputAutocapitalization(.never)
#endif
                .disableAutocorrection(true)
                .focused($focusedField, equals: .workingDirectory)
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text(workingDirectoryHelpText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if isWorkingDirectoryEmpty, serverType == .codexAppServer {
                    Text("Leave blank if you do not want a default working directory.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if hasAttemptedSave && isWorkingDirectoryEmpty && !allowsEmptyWorkingDirectory {
                    Label("A working directory is required for the agent to operate safely.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.footnote)
                }
                if hasAttemptedSave && isWorkingDirectoryRoot {
                    Label("Using root (/) as working directory is dangerous and may crash the agent.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.footnote)
                }
                Link(destination: URL(string: "https://agmente.halliharp.com/docs/guides/local-agent")!) {
                    Label("Need help? View the setup guide", systemImage: "questionmark.circle")
                }
                .font(.footnote)
            }
        }

        if showsGitCredentials {
            Section {
                NavigationLink {
                    GatewayGitCredentialsView(model: gitCredentials)
                } label: {
                    HStack {
                        Label("Git credentials", systemImage: "key")
                        Spacer()
                        Text("\(gitCredentials.credentials.count)")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityIdentifier("gitCredentialsRow")
                .accessibilityLabel("Git credentials, \(gitCredentials.credentials.count) saved")
                .task { await gitCredentials.load() }
            } header: {
                Text("Git")
            } footer: {
                Text("Tokens for private HTTPS repositories. Each token goes to your Mac once and cannot be read back.")
            }
        }

        Section {
            DisclosureGroup("Cloudflare Access", isExpanded: $showCloudflareAccess) {
                TextField("Client ID", text: $cfAccessClientId)
#if os(iOS)
                    .textInputAutocapitalization(.never)
#endif
                    .disableAutocorrection(true)
                    .focused($focusedField, equals: .cfAccessClientId)

                SecureField("Client Secret", text: $cfAccessClientSecret)
#if os(iOS)
                    .textInputAutocapitalization(.never)
#endif
                    .disableAutocorrection(true)
                    .focused($focusedField, equals: .cfAccessClientSecret)
            }
        }

#if !os(macOS)
        Section {
            Button {
                saveServer()
            } label: {
                HStack {
                    Spacer()
                    if isSaving {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .padding(.trailing, 8)
                    }
                    Text(editingServer == nil ? "Save Server" : "Update Server")
                        .fontWeight(.semibold)
                    Spacer()
                }
            }
            .disabled(!canSave)
            .accessibilityIdentifier("SaveServerButton")
            .accessibilityLabel(editingServer == nil ? "Save Server" : "Update Server")
        }
#endif
    }

    var body: some View {
        NavigationStack {
            ZStack {
                serverFormContainer
                .blur(radius: showingSummaryOverlay ? 3 : 0)
                .allowsHitTesting(!showingSummaryOverlay)

                if let validation = pendingValidation, showingSummaryOverlay {
                    Color.black.opacity(0.25)
                        .ignoresSafeArea()
                        .transition(.opacity)

                    ServerSummaryOverlay(
                        validation: validation,
                        workingDirectory: trimmedWorkingDirectory,
                        isEditing: editingServer != nil,
                        onConfirm: acknowledgeAndInsert,
                        onCancel: hideSummaryOverlay
                    )
                    .padding(.horizontal, 20)
                    .transition(.scale)
                }
            }
            .navigationTitle(editingServer == nil ? "Add Server" : "Edit Server")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        saveServer()
                    } label: {
                        HStack(spacing: 8) {
                            if isSaving {
                                ProgressView()
                                    .progressViewStyle(.circular)
                            }
                            Text(editingServer == nil ? "Save" : "Update")
                        }
                    }
                    .disabled(!canSave)
                    .accessibilityIdentifier("saveToolbarButton")
                }
            }
#if os(macOS)
            .frame(minWidth: 720, idealWidth: 760, minHeight: 620, idealHeight: 680)
#endif
        }
        .alert(editingServer == nil ? "Unable to Add Server" : "Unable to Update Server", isPresented: $showError) {
            Button("OK", role: .cancel) {
                showError = false
            }
        } message: {
            Text(errorMessage ?? "Failed to connect to the server. Check the endpoint and credentials, then try again.")
        }
    }
}

private extension AddServerView {
    var trimmedWorkingDirectory: String {
        workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    var isWorkingDirectoryEmpty: Bool {
        trimmedWorkingDirectory.isEmpty
    }
    
    var isWorkingDirectoryRoot: Bool {
        trimmedWorkingDirectory == "/"
    }

    var allowsEmptyWorkingDirectory: Bool {
        true
    }

    var workingDirectoryHelpText: String {
        switch serverType {
        case .codexAppServer:
            return "Optional for Codex. Used as the default working directory for new threads and cwd-scoped features like skills. Not required to add the server or load existing threads."
        case .acp:
            return "Some ACP agents require this when creating or listing sessions."
        }
    }
    
    var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !isSaving
    }
    
    func saveServer() {
        guard !isSaving else { return }
        focusedField = nil
        hasAttemptedSave = true

        if isWorkingDirectoryEmpty && !allowsEmptyWorkingDirectory {
            return
        }

        performSave()
    }
    
    func performSave() {
        isSaving = true
        let normalized = normalizeEndpointInput(host: host, scheme: scheme)
        Task {
            let result = await onValidate(
                name,
                normalized.scheme,
                normalized.host,
                token,
                cfAccessClientId,
                cfAccessClientSecret,
                workingDirectory,
                serverType,
                ServerSecurityInput(
                    localOnly: localOnly,
                    spkiPins: spkiPins,
                    clientIdentity: clientIdentity,
                    clientIdentityChanged: clientIdentityChanged
                )
            )
            await MainActor.run {
                isSaving = false
                switch result {
                case .success(let validation):
                    if let editingServer, Self.changesOnlyName(validation, from: editingServer) {
                        // A rename needs no acknowledgement: the connection and what the agent reports are unchanged.
                        onInsert(validation)
                        dismiss()
                    } else {
                        pendingValidation = validation
                        showingSummaryOverlay = true
                    }
                case .failure(let error):
                    // Check if this is a local network permission error
                    // If so, don't show an error alert to avoid interfering with the OS permission prompt
                    if let validationError = error as? AppViewModel.AddServerValidationError,
                       case .localNetworkPermissionNeeded = validationError {
                        // Don't show error alert for local network permission issues
                        // The OS will show its permission prompt, and user can try again after granting
                        return
                    }
                    errorMessage = error.localizedDescription
                    showError = true
                }
            }
        }
    }
    
    func normalizeHostInput(_ value: String) {
        guard !isNormalizingHost else { return }
        let normalized = normalizeEndpointInput(host: value, scheme: scheme)
        guard normalized.host != value || normalized.scheme != scheme else { return }

        isNormalizingHost = true
        host = normalized.host
        scheme = normalized.scheme
        isNormalizingHost = false
    }

    func normalizeEndpointInput(host: String, scheme: String) -> (scheme: String, host: String) {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseScheme = scheme.isEmpty ? "wss" : scheme

        guard let components = URLComponents(string: trimmedHost),
              let parsedHost = components.host
        else {
            return (baseScheme, trimmedHost)
        }

        let portString = components.port.map { ":\($0)" } ?? ""
        let path = components.percentEncodedPath
        let query = components.percentEncodedQuery.map { "?\($0)" } ?? ""
        let fragment = components.percentEncodedFragment.map { "#\($0)" } ?? ""

        let normalizedHost = parsedHost + portString + path + query + fragment
        let normalizedScheme = components.scheme ?? baseScheme

        return (normalizedScheme.isEmpty ? "wss" : normalizedScheme, normalizedHost)
    }

    func importPendingIdentity() {
        defer { pendingP12 = nil; p12Passphrase = "" }
        guard let data = pendingP12 else { return }
        do {
            clientIdentity = try ClientIdentityStore.importPKCS12(data, passphrase: p12Passphrase)
            clientIdentityChanged = true
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    /// The form offers ws:// only where FR-11 can allow it: Local only servers, or Debug builds (loopback).
    static func plaintextOffered(localOnly: Bool) -> Bool {
        localOnly || TransportPolicy.isDebugBuild
    }

    func hideSummaryOverlay() {
        showingSummaryOverlay = false
        pendingValidation = nil
    }

    func acknowledgeAndInsert() {
        guard let validation = pendingValidation else { return }
        onInsert(validation)
        hideSummaryOverlay()
        dismiss()
    }
}

extension AddServerView {
    /// True only for a working directory typed as "/" (surrounding whitespace ignored).
    static func isRootWorkingDirectory(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines) == "/"
    }

    /// True when an edit changes only the display name. The agent's reported capabilities and the
    /// connection (endpoint, token, Cloudflare Access, TLS pins and identity, local-only, agent kind,
    /// working directory) stay the same, so the agent-limitations acknowledgement is not needed.
    static func changesOnlyName(_ validation: ValidatedServerConfiguration, from original: ACPServerConfiguration) -> Bool {
        validation.scheme == original.scheme &&
        validation.host == original.host &&
        validation.token == original.token &&
        validation.cfAccessClientId == original.cfAccessClientId &&
        validation.cfAccessClientSecret == original.cfAccessClientSecret &&
        validation.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            == original.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines) &&
        validation.serverType == original.serverType &&
        validation.localOnly == original.localOnly &&
        validation.spkiPins == original.spkiPins &&
        !validation.clientIdentityChanged
    }
}

private struct ServerSummaryOverlay: View {
    let validation: ValidatedServerConfiguration
    let workingDirectory: String
    let isEditing: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    private var displayName: String {
        let trimmed = validation.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "\(validation.scheme)://\(validation.host)"
        }
        return trimmed
    }
    
    private var isWorkingDirectoryRoot: Bool {
        AddServerView.isRootWorkingDirectory(workingDirectory)
    }

    private var isCodexServer: Bool {
        validation.serverType == .codexAppServer || validation.agentInfo?.name == "codex-app-server"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Review agent limitations")
                        .font(.title3.weight(.semibold))
                    Text("Before inserting \(displayName), confirm what this server reports supporting.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Dismiss summary overlay")
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // Authentication notice (always shown)
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "person.badge.key.fill")
                            .foregroundStyle(.blue)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Authentication Required")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(
                                isCodexServer
                                ? "Make sure Codex CLI is already authenticated (for example, run `codex login`) before connecting. ACP Code does not handle Codex authentication."
                                : "Make sure you have authenticated with the agent CLI (OAuth, API key, etc.) before connecting. ACP Code does not handle agent authentication."
                            )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.blue.opacity(0.1))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.blue.opacity(0.3), lineWidth: 1)
                    )
                    
                    // Root directory warning
                    if isWorkingDirectoryRoot {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Root Directory Warning")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text("You are using root (/) as the working directory. The agent will have access to your entire filesystem, which may cause system instability or data loss.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.red.opacity(0.1))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.red.opacity(0.3), lineWidth: 1)
                        )
                    }

                    if isCodexServer && workingDirectory.isEmpty {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "folder.badge.questionmark")
                                .foregroundStyle(.secondary)
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("No Default Working Directory")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text("You can still connect and open existing threads. New threads will not have a preset working directory.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color(.systemGray6))
                        )
                    }
                    
                    if let agentInfo = validation.agentInfo {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(agentInfo.displayNameWithVersion)
                                .font(.headline)
                            if let description = agentInfo.description, !description.isEmpty {
                                Text(description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if isCodexServer {
                                CodexProtocolSummary()
                            } else {
                                AgentCapabilitiesSummary(
                                    capabilities: agentInfo.capabilities,
                                    verifications: agentInfo.verifications
                                )
                            }
                        }
                    } else {
                        Label {
                            Text("This agent did not provide capability details during validation. You can continue, but some features may be unavailable.")
                                .font(.subheadline)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color(.systemGray6))
                        )
                    }
                }
            }
            .frame(maxHeight: 360)

            VStack(spacing: 10) {
                Button(action: onConfirm) {
                    Text(isEditing ? "Acknowledge and Update" : "Acknowledge and Add")
                        .font(.headline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("serverSummaryConfirmButton")

                Button(action: onCancel) {
                    Text("Back to editing")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("serverSummaryBackButton")
            }
        }
        .padding(20)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(radius: 18)
    }
}
