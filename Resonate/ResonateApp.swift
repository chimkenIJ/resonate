//
//  ResonateApp.swift
//  Resonate
//
//  Created by Isha Jain on 10/9/26.
//

import SwiftUI

@main
struct ResonateApp: App {
    /// Mock services until the real ones land in build steps 3–7.
    @State private var app = AppModel(services: .mock())

    init() {
        #if DEBUG
        if let screen = ProcessInfo.processInfo.environment["RESONATE_SCREEN"] {
            _app = State(initialValue: .debugLaunch(screen: screen))
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .preferredColorScheme(.dark)
                .tint(Palette.textPrimary)
        }
    }
}
