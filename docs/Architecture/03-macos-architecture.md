# macOS architecture

The Mac application is a SwiftUI menu-bar process with AppKit floating panels. `AppState` is the composition root: it creates credentials and stores, wires the server to UI sinks, controls open/locked TLS modes, publishes Bonjour, and reacts to wake/network changes.

## Component architecture

```mermaid
flowchart TD
    subgraph APP["PhoneBridge executable — main actor"]
        MENU["PhoneBridgeApp<br/>MenuBarExtra"]
        STATE["AppState<br/>composition root and lifecycle"]
        QR["QR window"]
        HISTORY_UI["History window"]
        CARDS["NotificationCardController"]
        CALL_PANEL["CallPanelController"]
        STACK["ScreenStack<br/>top-right panel layout"]

        MENU --> STATE
        STATE --> QR
        STATE --> HISTORY_UI
        CARDS --> STACK
        CALL_PANEL --> STACK
    end

    subgraph CORE["PhoneBridgeCore"]
        SERVER["BridgeServer<br/>SwiftNIO listener"]
        HANDLER["RequestHandler<br/>auth, decode, validate, route"]
        REGISTRY["CallActionRegistry"]
        GATE["GatedSink"]
        HISTORY_SINK["HistorySink and<br/>CallHistorySink"]
        ENROLLER["EnrollmentCoordinator"]
        BONJOUR["BonjourAdvertiser"]

        SERVER --> HANDLER
        HANDLER --> GATE
        HANDLER <--> REGISTRY
        HANDLER --> ENROLLER
        GATE --> HISTORY_SINK
    end

    subgraph STORAGE["~/Library/Application Support/PhoneBridge"]
        PAIRING[("Server certificate/key<br/>and bearer token")]
        PHONE_CERT[("Enrolled phone certificate")]
        ICONS[("Content-addressed PNG icons")]
        HISTORY[("AES-GCM history<br/>and 256-bit key")]
    end

    STATE --> SERVER
    STATE --> BONJOUR
    STATE --> GATE
    STATE --> ENROLLER
    STATE <--> PAIRING
    ENROLLER --> PHONE_CERT
    SERVER <--> PHONE_CERT
    HANDLER <--> ICONS
    HISTORY_SINK --> HISTORY
    HISTORY_SINK --> CARDS
    HISTORY_SINK --> CALL_PANEL
    CALL_PANEL --> REGISTRY
    HISTORY_UI --> HISTORY

    classDef mac fill:#f3e8ff,stroke:#7c3aed,stroke-width:1.5px,color:#2e1065;
    classDef security fill:#fff3e0,stroke:#d97706,stroke-width:1.5px,color:#78350f;
    classDef data fill:#f3f4f6,stroke:#4b5563,stroke-width:1.5px,color:#111827;
    class MENU,STATE,QR,HISTORY_UI,CARDS,CALL_PANEL,STACK,SERVER,HANDLER,REGISTRY,GATE,HISTORY_SINK,BONJOUR mac;
    class ENROLLER security;
    class PAIRING,PHONE_CERT,ICONS,HISTORY data;
```

## Inbound server pipeline

Every accepted socket passes through the handlers in this order. Checks before TLS are intentionally cheap; application routing is reached only after transport trust succeeds.

```mermaid
flowchart LR
    SOCKET(["TCP connection<br/>0.0.0.0:52735"])
    SOURCE{"Private/loopback/<br/>CGNAT source?"}
    LIMIT{"Below 64 total and<br/>8 per source IP?"}
    IDLE["90-second idle reaper"]
    TLS{"TLS 1.2+ handshake<br/>locked mode: exact enrolled<br/>phone leaf certificate"}
    HTTP["HTTP/1.1 parser"]
    BODY{"Body at most 2 MiB?"}
    ROUTER["RequestHandler"]
    METHOD{"POST?"}
    TOKEN{"Constant-time bearer<br/>token match?"}
    VALIDATE["Decode and validate<br/>endpoint payload"]
    ENDPOINT["Notification, icon, dismiss,<br/>call, wait, or enrollment action"]
    CLOSE(["Silently close or<br/>return bounded JSON error"])

    SOCKET --> SOURCE
    SOURCE -- "No" --> CLOSE
    SOURCE -- "Yes" --> LIMIT
    LIMIT -- "No" --> CLOSE
    LIMIT -- "Yes" --> IDLE --> TLS
    TLS -- "Fail" --> CLOSE
    TLS -- "Pass" --> HTTP --> BODY
    BODY -- "No: 413" --> CLOSE
    BODY -- "Yes" --> ROUTER --> METHOD
    METHOD -- "No: 405" --> CLOSE
    METHOD -- "Yes" --> TOKEN
    TOKEN -- "No: 401" --> CLOSE
    TOKEN -- "Yes" --> VALIDATE
    VALIDATE -- "Invalid: 400/404/500" --> CLOSE
    VALIDATE -- "Valid" --> ENDPOINT

    classDef mac fill:#f3e8ff,stroke:#7c3aed,color:#2e1065;
    classDef decision fill:#fff3e0,stroke:#d97706,color:#78350f;
    classDef terminal fill:#f3f4f6,stroke:#4b5563,color:#111827;
    class SOCKET,IDLE,HTTP,ROUTER,VALIDATE,ENDPOINT mac;
    class SOURCE,LIMIT,TLS,BODY,METHOD,TOKEN decision;
    class CLOSE terminal;
```

The HTTP layer buffers a bounded body before bearer validation. The private-source gate, connection limits, idle timeout, and 2 MiB cap bound that exposure.

## Startup and lifecycle

```mermaid
flowchart TD
    START(["AppState initialization"])
    DIR["Create/protect application-support<br/>directory as mode 0700"]
    HISTORY_KEY{"History encryption<br/>key available?"}
    HISTORY_DISK["Load AES-GCM history<br/>and enable persistence"]
    HISTORY_MEMORY["Use memory-only history<br/>with no plaintext disk fallback"]
    CREDS["Pairing.ensure<br/>server cert, key, token"]
    ICONS["Open disk icon store"]
    ENROLLED{"Usable phone-cert.pem<br/>exists?"}
    LOCKED["Start BridgeServer<br/>locked mTLS mode"]
    OPEN["Start BridgeServer<br/>open enrollment mode"]
    PUBLISH["Publish _phonenotif._tcp.<br/>on actual listener port"]
    WATCH["Monitor wake and network path;<br/>refresh Bonjour and visible QR on IP change"]

    START --> DIR --> HISTORY_KEY
    HISTORY_KEY -- "Yes" --> HISTORY_DISK --> CREDS
    HISTORY_KEY -- "No" --> HISTORY_MEMORY --> CREDS
    CREDS --> ICONS --> ENROLLED
    ENROLLED -- "Yes" --> LOCKED --> PUBLISH
    ENROLLED -- "No" --> OPEN --> PUBLISH
    PUBLISH --> WATCH

    classDef mac fill:#f3e8ff,stroke:#7c3aed,color:#2e1065;
    classDef decision fill:#fff3e0,stroke:#d97706,color:#78350f;
    classDef data fill:#f3f4f6,stroke:#4b5563,color:#111827;
    class START,CREDS,ICONS,LOCKED,OPEN,PUBLISH,WATCH mac;
    class HISTORY_KEY,ENROLLED decision;
    class DIR,HISTORY_DISK,HISTORY_MEMORY data;
```

## Sink and presentation flow

`RequestHandler` depends on protocols rather than concrete UI classes. `AppState` builds this decorator chain:

```mermaid
flowchart LR
    NOTIFY["Validated /notify"] --> GATE{"Mac mirroring<br/>enabled?"}
    CALL["Validated /call"] --> GATE
    GATE -- "No" --> ACK["Acknowledge but do not<br/>display or add history"]
    GATE -- "Notification" --> NH["HistorySink<br/>record entry"] --> CARD["Notification card<br/>max 5, visible 6 seconds"]
    GATE -- "Call" --> CH["CallHistorySink<br/>record/update call"] --> PANEL["Persistent call panel"]
    DISMISS["Validated /dismiss"] --> CLEANUP["Cleanup bypasses display gate"]
    CLEANUP --> CARD
    CLEANUP --> PANEL

    classDef mac fill:#f3e8ff,stroke:#7c3aed,color:#2e1065;
    classDef decision fill:#fff3e0,stroke:#d97706,color:#78350f;
    classDef data fill:#f3f4f6,stroke:#4b5563,color:#111827;
    class NOTIFY,CALL,NH,CARD,CH,PANEL,DISMISS,CLEANUP mac;
    class GATE decision;
    class ACK data;
```

- Notification cards are custom non-activating `NSPanel` windows, not `UNUserNotificationCenter` banners. Clicking one closes it and opens history.
- Call cards have higher stack priority than ordinary cards and stay available for call actions.
- `ScreenStack` lays panels out at the top-right across Spaces without stealing keyboard focus.
- Dismiss/end cleanup always passes through even if mirroring was turned off after a card appeared.
- History dismissal is visual cleanup only; it does not delete the already-recorded history entry.

## Threading model

- `AppState` is `@MainActor`; SwiftUI/AppKit lifecycle and window changes stay on the main thread.
- `BridgeServer` uses one `MultiThreadedEventLoopGroup` thread. Its request handler may call thread-safe sinks from that event loop.
- Card and call-panel controllers dispatch presentation work to the main queue.
- `GatedSink`, `NotificationHistory`, `CallActionRegistry`, `EnrollmentCoordinator`, connection tracking, and connection limiting protect cross-thread mutable state with locks.
- `/call/wait` is the only asynchronous response path. All ordinary endpoints return synchronously after validation and dispatch.
- Production binds the fixed IPv4 listener `0.0.0.0:52735`. A brief three-attempt address-in-use retry handles a stale instance; there is no ephemeral-port fallback that would make the Android sweep contract lie.
- `AppState` can register the bundled application with `SMAppService` for start-at-login behavior; the menu-bar mirroring toggle is persisted in `UserDefaults` and immediately updates the thread-safe sink gate.

## Main source map

| Area | Implementation |
|---|---|
| Composition and server modes | [`AppState.swift`](../../mac/Sources/PhoneBridge/AppState.swift) |
| Menu-bar UI | [`PhoneBridgeApp.swift`](../../mac/Sources/PhoneBridge/PhoneBridgeApp.swift) |
| Network server and pre-TLS gates | [`BridgeServer.swift`](../../mac/Sources/PhoneBridgeCore/BridgeServer.swift) |
| Endpoint validation and routing | [`RequestHandler.swift`](../../mac/Sources/PhoneBridgeCore/RequestHandler.swift) |
| Server credentials and QR payload | [`Pairing.swift`](../../mac/Sources/PhoneBridgeCore/Pairing.swift) |
| Phone-certificate enrollment | [`PhoneEnrollment.swift`](../../mac/Sources/PhoneBridgeCore/PhoneEnrollment.swift) |
| Notification cards | [`NotificationCards.swift`](../../mac/Sources/PhoneBridge/NotificationCards.swift) |
| Call panel and actions | [`CallPanel.swift`](../../mac/Sources/PhoneBridge/CallPanel.swift), [`CallActionRegistry.swift`](../../mac/Sources/PhoneBridgeCore/CallActionRegistry.swift) |
| History and encryption | [`NotificationHistory.swift`](../../mac/Sources/PhoneBridgeCore/NotificationHistory.swift), [`HistoryCipher.swift`](../../mac/Sources/PhoneBridgeCore/HistoryCipher.swift) |
| Icon cache | [`IconStore.swift`](../../mac/Sources/PhoneBridgeCore/IconStore.swift) |
| Bonjour advertisement | [`BonjourAdvertiser.swift`](../../mac/Sources/PhoneBridgeCore/BonjourAdvertiser.swift) |
