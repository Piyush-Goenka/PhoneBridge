import AppKit
import SwiftUI
import PhoneBridgeCore

// Renders mirrored notifications as custom floating cards with the real app
// icon, replacing macOS notifications entirely. Cards auto-dismiss after a
// few seconds, close early when the notification is cleared on the phone
// (/dismiss), and can be clicked away.
final class NotificationCardController: NSObject, NotificationSink {

    // Main-thread only.
    private var cards: [String: NSPanel] = [:]
    private var order: [String] = []

    private let visibleFor: TimeInterval = 6
    private let maxVisible = 5

    func show(_ payload: NotifyPayload, iconPath: URL?) {
        let icon = iconPath.flatMap { NSImage(contentsOf: $0) }
        DispatchQueue.main.async { self.present(payload, icon: icon) }
    }

    func dismiss(key: String) {
        DispatchQueue.main.async { self.close(key: key) }
    }

    private func present(_ payload: NotifyPayload, icon: NSImage?) {
        close(key: payload.key)
        while order.count >= maxVisible, let oldest = order.first {
            close(key: oldest)
        }

        let key = payload.key
        let view = NotificationCardView(
            appName: payload.appName,
            title: payload.title,
            text: payload.text,
            icon: icon,
            onTap: { [weak self] in self?.close(key: key) })
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)

        let panel = makeCardPanel(hosting: hosting)
        cards[key] = panel
        order.append(key)
        ScreenStack.shared.add(panel, priority: 1)
        panel.orderFrontRegardless()

        NSSound(named: "Pop")?.play()

        let created = panel
        DispatchQueue.main.asyncAfter(deadline: .now() + visibleFor) { [weak self] in
            guard let self, self.cards[key] === created else { return }
            self.close(key: key)
        }
    }

    private func close(key: String) {
        guard let panel = cards.removeValue(forKey: key) else { return }
        order.removeAll { $0 == key }
        ScreenStack.shared.remove(panel)
        panel.close()
    }
}

struct NotificationCardView: View {
    let appName: String
    let title: String
    let text: String
    let icon: NSImage?
    let onTap: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.indigo.opacity(0.85))
                        Image(systemName: "bell.fill")
                            .font(.system(size: 17))
                            .foregroundStyle(.white)
                    }
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title.isEmpty ? appName : title)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(appName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if !text.isEmpty {
                    Text(text)
                        .font(.subheadline)
                        .foregroundStyle(.primary.opacity(0.85))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .frame(width: 360, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.white.opacity(0.12)))
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .onTapGesture(perform: onTap)
    }
}
