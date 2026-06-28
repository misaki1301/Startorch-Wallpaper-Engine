//
//  ikuyo_live_wallpaperApp.swift
//  ikuyo-live-wallpaper
//
//  Created by Paul Frank Pacheco Carpio on 27/06/26.
//

import SwiftUI
import SwiftData

@main
struct ikuyo_live_wallpaperApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Item.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
    }
}
