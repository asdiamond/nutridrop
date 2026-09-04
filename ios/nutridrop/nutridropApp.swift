//
//  nutridropApp.swift
//  nutridrop
//
//  Created by Aleksandr Diamond on 9/3/26.
//

import SwiftUI

@main
struct nutridropApp: App {
    @State private var authSession = AuthSession()

    var body: some Scene {
        WindowGroup {
            ContentView(authSession: authSession)
        }
    }
}
