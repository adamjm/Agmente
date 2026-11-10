import Foundation

enum ACPMethods {
    static let initialize = "initialize"
    static let sessionNew = "session/new"
    static let sessionLoad = "session/load"
    static let sessionResume = "session/resume"
    static let sessionPrompt = "session/prompt"
    static let sessionCancel = "session/cancel"
    static let sessionList = "session/list"
    static let sessionSetMode = "session/set_mode"
    /// Unstable model API (verify: not in upstream ACP schema as of 2026-11-10).
    static let sessionSetModel = "session/set_model"
    static let sessionDelete = "session/delete"
    static let sessionSetConfigOption = "session/set_config_option"
}
