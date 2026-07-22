//
//  KeraunosApp.swift
//  Keraunos
//
//  Created by Leo Sheng on 2026/6/15.
//

import SwiftUI

@main
struct KeraunosApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { TransferEngine.shared.handleForegroundActivation() }
                }
        }
    }
}
