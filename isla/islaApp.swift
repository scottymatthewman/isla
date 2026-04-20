//
//  islaApp.swift
//  isla
//
//  Created by Scotty Matthewman on 4/5/26.
//

import SwiftUI

@main
struct islaApp: App {
    @StateObject private var appStore = AppStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appStore)
        }
    }
}
