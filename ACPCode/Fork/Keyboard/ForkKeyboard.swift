#if canImport(UIKit)
import UIKit

/// Hides the keyboard by asking the current first responder to give up focus. The SwiftUI composer is a
/// UIKit text view underneath, so this reaches it from anywhere in the app. Safe to call when nothing has focus.
enum ForkKeyboard {
    @MainActor
    static func dismiss() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}
#endif
