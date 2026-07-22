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

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear { TransferEngine.shared.startIfNeeded() }
        }
    }
}
