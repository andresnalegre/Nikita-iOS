//
// NikitaNotifier.swift
//
// Nikita reaching out to the user on her own -- a local notification she fires
// through the notify_user tool when something is worth surfacing even if the
// user isn't looking at the chat. Not a script and not a schedule: it is her
// judgement, a small gesture of "I have something for you."
//

import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

public final class NikitaNotifier {
    public static let shared = NikitaNotifier()
    private init() {}

    // Ask permission the first time, then post. Best-effort and quiet on
    // failure -- a denied prompt just means the ping doesn't show, never a crash.
    public func reachOut(title: String, body: String) async {
        #if canImport(UserNotifications)
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(
            options: [.alert, .sound])) ?? false
        guard granted else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        try? await center.add(req)
        #endif
    }
}
