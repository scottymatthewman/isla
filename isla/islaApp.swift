//
//  islaApp.swift
//  isla
//
//  Created by Scotty Matthewman on 4/5/26.
//

import SwiftUI
import CoreData

@main
struct islaApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
