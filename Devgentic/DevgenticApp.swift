// AgenticDevApp.swift

import SwiftUI

@main
struct AgenticDevApp: App {
    var body: some Scene {
        WindowGroup {
            MainApplicationView()
                .frame(minWidth: 800, minHeight: 500)
        }
        // --- ONLY apply this modifier for testing ---
        .windowStyle(.hiddenTitleBar)
    }
}
