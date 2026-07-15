import Foundation
import UserNotifications

public final class Notifier: NSObject, NotificationSink, UNUserNotificationCenterDelegate {
    private var isBundled: Bool { Bundle.main.bundleIdentifier != nil }

    public override init() {
        super.init()
    }

    public func activate(onDenied: @escaping () -> Void) {
        guard isBundled else {
            print("[dev] running unbundled, notifications print to stdout")
            return
        }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            if !granted {
                DispatchQueue.main.async { onDenied() }
            }
        }
    }

    public func show(_ payload: NotifyPayload, iconPath: URL?) {
        guard isBundled else {
            print("[dev] notify \(payload.appName): \(payload.title): \(payload.text)")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = payload.title.isEmpty ? payload.appName : payload.title
        content.subtitle = payload.title.isEmpty ? "" : payload.appName
        content.body = payload.text
        content.sound = .default

        if let iconPath {
            // UNNotificationAttachment takes ownership of the file and moves it,
            // so attach a throwaway copy, never the cached original.
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".png")
            if (try? FileManager.default.copyItem(at: iconPath, to: tmp)) != nil,
               let attachment = try? UNNotificationAttachment(identifier: "icon", url: tmp) {
                content.attachments = [attachment]
            }
        }

        let request = UNNotificationRequest(
            identifier: payload.key, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    public func dismiss(key: String) {
        guard isBundled else {
            print("[dev] dismiss \(key)")
            return
        }
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: [key])
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
