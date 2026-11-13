import SwiftUI

// Each connection has a colour. The colour marks its sessions in the drawer and the top bar, so a session can
// be matched to its connection at a glance. The colour is chosen from the connection's place in the list, so it
// is stable while the list is unchanged. The palette avoids green, orange and red, which the app uses for
// connection and approval states.

enum ServerColour {
    /// The palette, in order. Index 0 goes to the first connection in the list.
    static let palette: [Color] = [
        .blue,
        .purple,
        .teal,
        .pink,
        .indigo,
        .cyan,
        .brown,
        .yellow
    ]

    /// The palette index for the connection at `position` in the connection list. Wraps after the palette runs
    /// out. A negative position (no connection) maps to 0.
    static func paletteIndex(position: Int) -> Int {
        guard position > 0 else { return 0 }
        return position % palette.count
    }

    static func color(index: Int) -> Color {
        let safe = index >= 0 ? index % palette.count : 0
        return palette[safe]
    }

    /// The dot that shows a connection is open.
    static let connectedDot = Color(.sRGB, red: 73 / 255, green: 210 / 255, blue: 123 / 255, opacity: 1)
    /// The dot that shows a connection is not open.
    static let offlineDot = Color(.systemGray3)
}
