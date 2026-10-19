import SwiftUI

@main
struct NashStandApp: App {
    @StateObject private var store = Store()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(store)
                .tint(Theme.green)
        }
    }
}

/// Colors shared with Nash on the Mac.
enum Theme {
    static let green = Color(red: 0x1F / 255, green: 0x4D / 255, blue: 0x3A / 255)
    static let cream = Color(red: 0xF3 / 255, green: 0xF0 / 255, blue: 0xE7 / 255)
    static let lime = Color(red: 0xCC / 255, green: 0xE9 / 255, blue: 0x69 / 255)
    static let stand = Color(white: 0.13)
}
