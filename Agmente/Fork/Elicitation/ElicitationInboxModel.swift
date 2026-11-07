import Foundation

/// The forms waiting for an answer on this device (FR-44). The first one is shown. A form has no swipe
/// dismiss: the person answers it, or the gateway closes it when another device answers first.
@MainActor
final class ElicitationInboxModel: ObservableObject {
    @Published private(set) var forms: [ElicitationFormModel] = []
    /// Said once when a form was closed without this device's answer.
    @Published var notice: String?

    var current: ElicitationFormModel? { forms.first }

    /// Shows a form the gateway asked for. A form with the same id is shown once.
    func present(_ request: ElicitationRequest, answering: ElicitationAnswering) {
        guard !forms.contains(where: { $0.request.id == request.id }) else { return }
        let form = ElicitationFormModel(request: request, answering: answering)
        form.onFinish = { [weak self, weak form] note in
            guard let self, let form else { return }
            self.remove(form)
            if let note { self.notice = note }
        }
        forms.append(form)
    }

    /// The gateway logged `_agmente/elicitation_answered`: the form is closed on every device.
    func closed(elicitationId: String, answeredBy: String?) {
        guard let form = forms.first(where: { $0.request.id == elicitationId }) else { return }
        form.closedByGateway(note: "The agent's question was answered elsewhere or closed (\(answeredBy ?? "closed")).")
    }

    private func remove(_ form: ElicitationFormModel) {
        forms.removeAll { $0 === form }
    }
}
