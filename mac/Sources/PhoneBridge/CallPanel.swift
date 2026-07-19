import AppKit
import SwiftUI
import PhoneBridgeCore

// A floating incoming-call card in the top-right corner of the screen.
// Unlike a notification banner it stays visible until a button is clicked,
// the ring ends (phone sends /dismiss), or the action window expires.
final class CallPanelController: NSObject, CallSink {

    var onAction: ((String, CallAction) -> Void)?

    // Main-thread only.
    private struct Session {
        let panel: NSPanel
        var caller: String
        var state: CallState?
    }
    private var sessions: [String: Session] = [:]

    // A ringing card outlives the ring itself only as a safety net: the real
    // close comes from the phone's /dismiss. Once the call is answered it can
    // last as long as the call does, so the net moves far out.
    private let ringingSafetyNet: TimeInterval = 180
    private let inCallSafetyNet: TimeInterval = 4 * 60 * 60

    func showCall(key: String, caller: String) {
        DispatchQueue.main.async { self.present(key: key, caller: caller) }
    }

    // Caller-name correction while the same call is still ringing: swap the
    // text on the existing panel. No new sound, no timer reset, no restack.
    func updateCall(key: String, caller: String) {
        DispatchQueue.main.async {
            guard var session = self.sessions[key] else { return }
            session.caller = caller
            self.sessions[key] = session
            self.refresh(key: key)
        }
    }

    // The phone confirmed the call went active (answered from here) or that
    // its ringer is now silenced. Only the phone can tell us this, so the
    // card never claims something that did not actually happen.
    func setCallState(key: String, state: CallState) {
        DispatchQueue.main.async {
            guard var session = self.sessions[key] else { return }
            session.state = state
            self.sessions[key] = session
            self.refresh(key: key)
            if state == .active { self.armSafetyNet(key: key, after: self.inCallSafetyNet) }
        }
    }

    func endCall(key: String) {
        DispatchQueue.main.async { self.close(key: key) }
    }

    private func present(key: String, caller: String) {
        close(key: key)

        let hosting = NSHostingView(rootView: CallPanelView(caller: caller, state: nil))
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)

        let panel = makeCardPanel(hosting: hosting)
        sessions[key] = Session(panel: panel, caller: caller, state: nil)
        refresh(key: key)
        ScreenStack.shared.add(panel, priority: 0)
        panel.orderFrontRegardless()

        NSSound(named: "Glass")?.play()
        armSafetyNet(key: key, after: ringingSafetyNet)
    }

    private func refresh(key: String) {
        guard let session = sessions[key],
              let hosting = session.panel.contentView as? NSHostingView<CallPanelView>
        else { return }
        hosting.rootView = CallPanelView(
            caller: session.caller,
            state: session.state,
            onAnswer: { [weak self] in self?.send(key: key, action: .answer) },
            onSilence: { [weak self] in self?.send(key: key, action: .silence) },
            onReject: { [weak self] in self?.finish(key: key, action: .reject) },
            onEnd: { [weak self] in self?.finish(key: key, action: .end) })
        let size = hosting.fittingSize
        if size != session.panel.frame.size {
            hosting.frame = NSRect(origin: .zero, size: size)
            session.panel.setContentSize(size)
            ScreenStack.shared.relayout()
        }
    }

    // Answer and Silence leave the call alive, so the card stays: it is the
    // phone's confirmation (setCallState) that changes what the card shows.
    private func send(key: String, action: CallAction) {
        onAction?(key, action)
    }

    // Reject and End terminate the call, so the card goes immediately rather
    // than waiting for the phone's /dismiss to make the round trip.
    private func finish(key: String, action: CallAction) {
        onAction?(key, action)
        close(key: key)
    }

    private func armSafetyNet(key: String, after delay: TimeInterval) {
        let panel = sessions[key]?.panel
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, let current = self.sessions[key]?.panel, current === panel else {
                return
            }
            self.close(key: key)
        }
    }

    private func close(key: String) {
        guard let session = sessions.removeValue(forKey: key) else { return }
        ScreenStack.shared.remove(session.panel)
        session.panel.close()
    }
}

struct CallPanelView: View {
    let caller: String
    // nil while ringing; .silenced still ringing, .active answered from here.
    let state: CallState?
    var onAnswer: () -> Void = {}
    var onSilence: () -> Void = {}
    var onReject: () -> Void = {}
    var onEnd: () -> Void = {}

    @State private var pulsing = false

    private var isActive: Bool { state == .active }

    private var subtitle: String {
        switch state {
        case .active: return "On call, audio is on your phone"
        case .silenced: return "Ringer silenced, still ringing"
        case nil: return "Incoming call on your phone"
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill((isActive ? Color.accentColor : Color.green).opacity(0.9))
                    .frame(width: 46, height: 46)
                    .scaleEffect(pulsing && !isActive ? 1.08 : 1.0)
                    .animation(
                        .easeInOut(duration: 0.7).repeatForever(autoreverses: true),
                        value: pulsing)
                Image(systemName: isActive ? "waveform" : "phone.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .onAppear { pulsing = true }

            VStack(alignment: .leading, spacing: 3) {
                Text(caller)
                    .font(.headline)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            VStack(spacing: 8) {
                if isActive {
                    Button(action: onEnd) {
                        Label("End call", systemImage: "phone.down.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                } else {
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
                        Label(
                            state == .silenced ? "Silenced" : "Silence",
                            systemImage: "bell.slash.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(state == .silenced)
                }
            }
            .frame(width: 116)
        }
        .padding(18)
        .frame(width: 360)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(
                    (isActive ? Color.accentColor : Color.green).opacity(0.35),
                    lineWidth: 1.5))
    }
}
