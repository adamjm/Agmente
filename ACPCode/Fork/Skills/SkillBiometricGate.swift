import Foundation
import LocalAuthentication

/// Confirms that the owner is present before a skill is saved (FR-43, PLAN 6B.3, owner decision 7).
///
/// This is a control in the app, not a check on the server: the gateway cannot see Face ID. The
/// audit line for a save shows which device sent it. The gate stores nothing.
protocol SkillSaveGate: Sendable {
    /// True only when the owner has confirmed. The model sends the save request only after `true`.
    func confirmSave(skillName: String) async -> Bool
}

/// The LocalAuthentication gate. It uses biometrics only (`.deviceOwnerAuthenticationWithBiometrics`),
/// so a passcode does not satisfy it. A device with no enrolled Face ID or Touch ID cannot save a
/// skill; that is the stated trade-off of owner decision 7.
struct BiometricSkillSaveGate: SkillSaveGate {
    private let policy: LAPolicy = .deviceOwnerAuthenticationWithBiometrics

    func confirmSave(skillName: String) async -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        var error: NSError?
        guard context.canEvaluatePolicy(policy, error: &error) else { return false }
        do {
            return try await context.evaluatePolicy(
                policy,
                localizedReason: "Save the skill \"\(skillName)\" to this project"
            )
        } catch {
            return false
        }
    }
}
