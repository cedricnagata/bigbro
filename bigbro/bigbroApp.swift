//
//  bigbroApp.swift
//  bigbro
//
//  Created by Cedric Nagata on 4/20/26.
//

import SwiftUI
import CoreData

@main
struct bigbroApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
