import SwiftUI
import ACPClient

/// Model picker shown next to the mode menu in an ACP session.
///
/// Two sources, one picker. A select config option with category `model` (or id `model`) wins; otherwise
/// the unstable `models` list from the session response is used (verify: not in upstream ACP schema).
/// When neither exists, nothing is shown, so a session never has two model pickers.
struct SessionModelMenu: View {
    @ObservedObject var sessionViewModel: ACPSessionViewModel
    let sessionId: String
    let serverId: UUID?

    var body: some View {
        if let option = sessionViewModel.modelConfigOption,
           case .select(let choices) = option.kind {
            configOptionMenu(option: option, choices: choices)
        } else if !sessionViewModel.availableModels.isEmpty {
            modelsMenu
        }
    }

    // MARK: - Unstable `models` list

    private var modelsMenu: some View {
        Menu {
            ForEach(sessionViewModel.availableModels) { model in
                Button {
                    sessionViewModel.sendSetModel(model.id, sessionId: sessionId, serverId: serverId)
                } label: {
                    HStack {
                        Text(model.name)
                        if sessionViewModel.currentModelId == model.id {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            pillLabel(title: currentModelName)
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel("Model")
        .accessibilityIdentifier("modelMenu")
    }

    private var currentModelName: String {
        if let modelId = sessionViewModel.currentModelId,
           let model = sessionViewModel.availableModels.first(where: { $0.id == modelId }) {
            return model.name
        }
        return sessionViewModel.availableModels.first?.name ?? "Model"
    }

    // MARK: - Config option with category `model`

    private func configOptionMenu(option: ACPSessionConfigOption, choices: [ACPSessionConfigOptionChoice]) -> some View {
        Menu {
            ForEach(choices) { choice in
                Button {
                    sessionViewModel.sendSetConfigOption(
                        configId: option.id,
                        value: .string(choice.id),
                        sessionId: sessionId,
                        serverId: serverId
                    )
                } label: {
                    HStack {
                        Text(choice.name)
                        if option.currentValue.stringValue == choice.id {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            pillLabel(title: option.selectedChoiceName ?? option.name)
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel("Model")
        .accessibilityIdentifier("modelMenu")
    }

    // MARK: - Shared label

    private func pillLabel(title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "cpu")
                .font(.footnote.weight(.semibold))
            Text(title)
                .font(.footnote.weight(.medium))
                .fixedSize()
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .fixedSize()
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(.systemGray5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
