//
//  Deep_InsightApp.swift
//  Deep Insight
//
//  Created by Joe Shaji on 17/04/26.
//

import SwiftUI
import CoreData

@main
struct Deep_InsightApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
