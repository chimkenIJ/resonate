//
//  ResonateApp.swift
//  Resonate
//
//  Created by Isha Jain on 10/9/26.
//

import SwiftUI

@main
struct ResonateApp: App {
    /// Live services when ResonateConfig.plist is filled in, mocks otherwise.
    @State private var app = AppModel(services: .makeDefault())

    init() {
        #if DEBUG
        if let screen = ProcessInfo.processInfo.environment["RESONATE_SCREEN"] {
            let live = ProcessInfo.processInfo.environment["RESONATE_LIVE"] == "1"
            _app = State(initialValue: .debugLaunch(screen: screen, live: live))
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
