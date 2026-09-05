//
//  nutridropApp.swift
//  nutridrop
//
//  Created by Aleksandr Diamond on 9/3/26.
//

import SwiftUI

@main
struct nutridropApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(authSession: appDelegate.authSession)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        UIApplication.shared.registerForRemoteNotifications()
                    }
                }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    let authSession = AuthSession()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        authSession.receivedPushToken(deviceToken.map { String(format: "%02x", $0) }.joined())
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        authSession.pushRegistrationStatus = "APNs registration failed: \(error.localizedDescription)"
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        guard authSession.isAuthenticated,
              let recordID = userInfo["record_id"] as? String,
              UUID(uuidString: recordID) != nil else {
            completionHandler(.noData)
            return
        }
        authSession.receivedPush(recordID: recordID)
        Task {
            let result = await authSession.syncPendingNutrition()
            completionHandler(result)
        }
    }
}
