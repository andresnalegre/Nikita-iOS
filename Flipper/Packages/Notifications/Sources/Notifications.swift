import UIKit

import FirebaseCore
import FirebaseMessaging

@MainActor
public class Notifications: NSObject, ObservableObject {
    public static let shared: Notifications = .init()

    let firmwareReleaseTopic = "flipper_update_firmware_release"

    public enum Error: Swift.Error {
        case notAllowed
    }

    public var isEnabled: Bool {
        get async {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            return settings.authorizationStatus == .authorized &&
                UIApplication.shared.isRegisteredForRemoteNotifications
        }
    }

    private override init() {
        super.init()
        setup()
    }

    private func setup() {
        FirebaseApp.configure()

        Messaging.messaging().delegate = self

        UNUserNotificationCenter.current().delegate = self
    }

    public func enable() async throws {
        let center = UNUserNotificationCenter.current()
        var settings = await center.notificationSettings()

        guard settings.authorizationStatus != .denied else {
            throw Error.notAllowed
        }

        if settings.authorizationStatus == .notDetermined {
            try await requestAuthorization()
            settings = await center.notificationSettings()
        }

        guard settings.authorizationStatus == .authorized else {
            throw Error.notAllowed
        }

        UIApplication.shared.registerForRemoteNotifications()
    }

    func requestAuthorization() async throws {
        do {
            let center = UNUserNotificationCenter.current()
            let options: UNAuthorizationOptions = [.alert, .badge, .sound]
            try await center.requestAuthorization(options: options)
        } catch {
            throw Error.notAllowed
        }
    }

    public func disable() async {
        do {
            let messaging = Messaging.messaging()
            if messaging.apnsToken != nil, messaging.fcmToken != nil {
                try await messaging.deleteToken()
            }
        } catch {
            logger.error("delete token: \(error)")
        }

        UIApplication.shared.unregisterForRemoteNotifications()
    }
}

extension Notifications: UNUserNotificationCenterDelegate {
    // Present notifications even when the app is in the FOREGROUND. Without
    // this, iOS silently drops any local or push notification that fires while
    // the app is open -- which is exactly when Nikita reaches out mid-chat, so
    // nothing arrived even with notifications fully enabled. This is the single
    // delegate for the whole app, so it covers both Nikita's own local pings
    // (notify_user) and Firebase pushes.
    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound, .badge])
    }
}

extension Notifications: MessagingDelegate {
    public func messaging(
        _ messaging: Messaging,
        didReceiveRegistrationToken fcmToken: String?
    ) {
        #if DEBUG
        print("Firebase registration token: \(String(describing: fcmToken))")
        #endif

        if messaging.apnsToken != nil, fcmToken != nil {
            messaging.subscribe(toTopic: firmwareReleaseTopic)
        }

        // TODO: If necessary send token to application server.
        // Note: This callback is fired at each app startup and whenever
        // a new token is generated.
    }
}
