import AppKit
import SwiftUI
import PhoneBridgeCore

// A floating incoming-call card in the top-right corner of the screen.
// Unlike a notification banner it stays visible until a button is clicked,
// the ring ends (phone sends /dismiss), or the action window expires.
final class CallPanelController: NSObject, CallSink {

    var onAction: ((String, CallAction) -> Void)?

    // Main-thread only.
    private var panels: [String: NSPanel] = [:]

    // Matches the CallActionRegistry timeout so the panel never outlives the
    // window in which a click can still reach the phone.
    private let visibleFor: TimeInterval = 45

    func showCall(key: String, caller: String) {
        DispatchQueue.main.async { self.present(key: key, caller: caller) }
    }

    func endCall(key: String) {
        DispatchQueue.main.async { self.close(key: key) }
    }

    private func present(key: String, caller: String) {
        close(key: key)

        let view = CallPanelView(
            caller: caller,
            onAnswer: { [weak self] in self?.finish(key: key, action: .answer) },
            onSilence: { [weak self] in self?.finish(key: key, action: .silence) },
            onReject: { [weak self] in self?.finish(key: key, action: .reject) })
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)

        let panel = makeCardPanel(hosting: hosting)
        panels[key] = panel
        ScreenStack.shared.add(panel, priority: 0)
        panel.orderFrontRegardless()

        NSSound(named: "Glass")?.play()

        let created = panel
        DispatchQueue.main.asyncAfter(deadline: .now() + visibleFor) { [weak self] in
            guard let self, self.panels[key] === created else { return }
            self.close(key: key)
        }
    }

    private func finish(key: String, action: CallAction) {
        onAction?(key, action)
        close(key: key)
    }

    private func close(key: String) {
        guard let panel = panels.removeValue(forKey: key) else { return }
        ScreenStack.shared.remove(panel)
        panel.close()
    }
}

struct CallPanelView: View {
    let caller: String
    let onAnswer: () -> Void
    let onSilence: () -> Void
    let onReject: () -> Void

    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.9))
                    .frame(width: 46, height: 46)
                    .scaleEffect(pulsing ? 1.08 : 1.0)
                    .animation(
                        .easeInOut(duration: 0.7).repeatForever(autoreverses: true),
                        value: pulsing)
                Image(systemName: "phone.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .onAppear { pulsing = true }

            VStack(alignment: .leading, spacing: 3) {
                Text(caller)
                    .font(.headline)
                    .lineLimit(1)
                Text("Incoming call on your phone")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            VStack(spacing: 8) {
                Button(action: onAnswer) {
                    Label("Answer", systemImage: "phone.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)

                Button(action: onReject) {
                    Label("Reject", systemImage: "phone.down.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)

                Button(action: onSilence) {
                    Label("Silence", systemImage: "bell.slash.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .frame(width: 116)
        }
        .padding(18)
        .frame(width: 360)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Color.green.opacity(0.35), lineWidth: 1.5))
    }
}
