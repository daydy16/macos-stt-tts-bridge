//
//  STTBridgeApp.swift
//  STTBridge
//
//  Created by David Fankhänel on 26.10.25.
//

import SwiftUI
import CoreData

@main
struct STTBridgeApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
