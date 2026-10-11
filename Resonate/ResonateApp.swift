//
//  ResonateApp.swift
//  Resonate
//
//  Created by Isha Jain on 10/9/26.
//

import AppIntents
import SwiftUI

@main
struct ResonateApp: App {
    /// Live services when ResonateConfig.plist is filled in, mocks otherwise.
    @State private var app: AppModel

    init() {
        var model: AppModel?
        #if DEBUG
        if let screen = ProcessInfo.processInfo.environment["RESONATE_SCREEN"] {
            let live = ProcessInfo.processInfo.environment["RESONATE_LIVE"] == "1"
            model = .debugLaunch(screen: screen, live: live)
        }
        #endif
        let app = model ?? AppModel(services: .makeDefault())
        _app = State(initialValue: app)
        // Siri and Shortcuts intents act on this same model.
        AppDependencyManager.shared.add(dependency: app)
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
