# PhoneBridge architecture

This directory documents the architecture that is implemented in the repository as of 2026-07-22. PhoneBridge is a peer-to-peer bridge: the Android phone sends selected notifications and call events directly to the macOS menu-bar app over the local/private network. There is no cloud service or account backend in the data path.

The diagrams use Mermaid and are intended to render directly in GitHub and other Mermaid-aware Markdown viewers.

## Reading guide

| Document | What it explains |
|---|---|
| [System overview](01-system-overview.md) | System boundary, deployment, major components, core design rules, and the protocol surface |
| [Android architecture](02-android-architecture.md) | Compose UI, notification listener, filters, call control, pairing storage, discovery, and transport |
| [macOS architecture](03-macos-architecture.md) | Menu-bar app, SwiftNIO server pipeline, request routing, sinks, floating cards, history, and storage |
| [Pairing and connection](04-pairing-and-connection.md) | QR bootstrap, certificate enrollment, steady-state mTLS, address recovery, server modes, and unpairing |
| [Notification lifecycle](05-notification-lifecycle.md) | End-to-end notification delivery, icon negotiation, dismissal, validation, retry, and drop behavior |
| [Call control](06-call-control.md) | Incoming-call detection, long polling, action delivery, state changes, caller updates, and cleanup |
| [Security and data](07-security-and-data.md) | Trust boundaries, layered controls, credentials, at-rest data, limits, and recovery behavior |

The wire-level source of truth remains [protocol.md](../../protocol.md). These documents explain how the two implementations realize that contract.

## Diagram legend

The same colors are used throughout the set:

- Blue: Android or phone-owned behavior.
- Purple: macOS-owned behavior.
- Green: LAN transport and discovery.
- Amber: authentication, validation, or another security decision.
- Gray: persistent or in-memory state.

## Scope and architectural constraints

- One Android phone is enrolled at a time; the Mac stores one phone certificate.
- The bridge is intended for a LAN or private VPN, not a public internet endpoint.
- Normal notification delivery is best effort: there is no durable Android queue and no replay after reconnect.
- Discovery runs on demand after a cached-address failure. It is not a continuous background browser.
- A long-lived request exists only while a mirrored phone call is active; it is implemented as repeated bounded long polls.
- Regular notifications are display-only on the Mac. Call cards additionally support Answer, Reject, Silence, and End call.

## Source layout

```text
Phone-Notification/
├── android/                         Kotlin Android application
│   └── app/src/main/java/com/piyush/phonebridge/
│       ├── filter/                  Forward/drop and duplicate decisions
│       ├── model/                   Relay payload model
│       ├── net/                     TLS, HTTP, enrollment, and discovery
│       ├── pairing/                 QR parsing and encrypted pairing state
│       ├── relay/                   Notification listener and call control
│       └── ui/                      Jetpack Compose application
├── mac/                             Swift macOS application
│   └── Sources/
│       ├── PhoneBridge/             AppKit/SwiftUI UI and composition root
│       └── PhoneBridgeCore/         Server, protocol handlers, and stores
├── docs/Architecture/               This documentation set
└── protocol.md                      Versioned Android-to-Mac wire contract
```

