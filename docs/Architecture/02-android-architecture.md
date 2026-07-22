# Android architecture

The Android application separates user configuration from the background relay. `MainActivity` owns pairing and settings UX; `NotificationRelayService` owns notification/call events and performs network work on an I/O coroutine scope.

## Component flow

```mermaid
flowchart TD
    subgraph INPUTS["Android platform inputs"]
        OS_NOTIF["Notification manager<br/>posted / removed callbacks"]
        TELEPHONY["Telephony and Telecom APIs"]
        WIFI["ConnectivityManager and NSD"]
        PACKAGES["PackageManager<br/>labels and app icons"]
    end

    subgraph UI["Presentation and user configuration"]
        MAIN["MainActivity"]
        COMPOSE["MainScreen<br/>Home / Apps / Activity tabs"]
        QR["ZXing QR scanner"]
        MAIN --> COMPOSE
        MAIN --> QR
    end

    subgraph RELAY["Event and policy layer"]
        SERVICE["NotificationRelayService"]
        EXTRACT["Extract and bound fields"]
        CALL_DECIDE["CallSessionDecider"]
        FILTER["NotificationFilter"]
        DEDUP["DedupCache<br/>30-second window"]
        CALL_CONTROL["CallControl"]

        SERVICE --> EXTRACT
        EXTRACT --> CALL_DECIDE
        EXTRACT --> FILTER
        FILTER --> DEDUP
        CALL_DECIDE --> CALL_CONTROL
    end

    subgraph NETWORK["Connection layer"]
        CLIENT["MacClient<br/>OkHttp HTTPS POST"]
        RESOLVER["HostResolver"]
        MDNS["MacDiscovery<br/>bounded mDNS"]
        SWEEP["SweepPlan and SweepProber<br/>pinned TLS verification"]
        ENROLL["Enrollment"]

        RESOLVER --> MDNS
        RESOLVER --> SWEEP
        CLIENT --> ENROLL
    end

    subgraph STATE["State and credentials"]
        STORE[("PairingStore<br/>encrypted preferences")]
        ID[("ClientIdentity<br/>Android Keystore EC P-256")]
        LOG[("SendLog<br/>memory-only, last 20")]
        ICON_CACHE[("AppIcons<br/>memory cache")]
    end

    OS_NOTIF --> SERVICE
    TELEPHONY <--> CALL_CONTROL
    WIFI --> RESOLVER
    PACKAGES --> EXTRACT
    PACKAGES --> ICON_CACHE
    QR --> MAIN
    MAIN <--> STORE
    MAIN <--> ID
    SERVICE <--> STORE
    SERVICE --> CLIENT
    SERVICE --> RESOLVER
    SERVICE --> ICON_CACHE
    SERVICE --> LOG
    CLIENT <--> ID
    ENROLL <--> STORE

    classDef android fill:#e8f1ff,stroke:#2563eb,stroke-width:1.5px,color:#172554;
    classDef network fill:#e8f8ee,stroke:#15803d,stroke-width:1.5px,color:#14532d;
    classDef security fill:#fff3e0,stroke:#d97706,stroke-width:1.5px,color:#78350f;
    classDef data fill:#f3f4f6,stroke:#4b5563,stroke-width:1.5px,color:#111827;
    class OS_NOTIF,TELEPHONY,WIFI,PACKAGES,MAIN,COMPOSE,QR,SERVICE,EXTRACT,CALL_DECIDE,FILTER,DEDUP,CALL_CONTROL android;
    class CLIENT,RESOLVER,MDNS,SWEEP network;
    class ENROLL,ID security;
    class STORE,LOG,ICON_CACHE data;
```

## Posted-notification decision flow

```mermaid
flowchart TD
    START(["onNotificationPosted"])
    READY{"Paired and global<br/>mirroring enabled?"}
    EXTRACT["Extract key, package, app name,<br/>title, text, timestamp, flags, category<br/>and truncate to protocol bounds"]
    CALL{"Default-dialer call category<br/>and call mirroring enabled?"}
    CALL_STATE["CallSessionDecider<br/>start, update, end, or ignore"]
    STRUCT{"Pass structural filters?<br/>not ongoing / group summary / noisy category"}
    ALLOWED{"Package in allowlist and<br/>title or text is non-empty?"}
    DUP{"Same package + title + text<br/>seen in last 30 seconds?"}
    DELIVER["Build /notify payload,<br/>resolve icon, attempt delivery"]
    CALL_PATH["Run dedicated call session path"]
    DROP(["Return without network work"])

    START --> READY
    READY -- "No" --> DROP
    READY -- "Yes" --> EXTRACT
    EXTRACT --> CALL
    CALL -- "Yes" --> CALL_STATE --> CALL_PATH
    CALL -- "No" --> STRUCT
    STRUCT -- "No" --> DROP
    STRUCT -- "Yes" --> ALLOWED
    ALLOWED -- "No" --> DROP
    ALLOWED -- "Yes" --> DUP
    DUP -- "Yes" --> DROP
    DUP -- "No" --> DELIVER

    classDef android fill:#e8f1ff,stroke:#2563eb,color:#172554;
    classDef decision fill:#fff3e0,stroke:#d97706,color:#78350f;
    classDef terminal fill:#f3f4f6,stroke:#4b5563,color:#111827;
    class START,EXTRACT,DELIVER,CALL_PATH,CALL_STATE android;
    class READY,CALL,STRUCT,ALLOWED,DUP decision;
    class DROP terminal;
```

The call route is evaluated before the ordinary structural filter because dialer call notifications are normally ongoing and would otherwise be dropped. VoIP apps using the `call` category still follow the regular allowlist path; only the system default dialer receives telephony actions.

## Main classes and ownership

| Component | Responsibility | State/lifetime |
|---|---|---|
| [`MainActivity`](../../android/app/src/main/java/com/piyush/phonebridge/ui/MainActivity.kt) | QR scan, endpoint verification, replacement confirmation, enrollment, reachability status, unpair, permissions | Activity/UI lifetime |
| [`MainScreen`](../../android/app/src/main/java/com/piyush/phonebridge/ui/MainScreen.kt) and tabs | Home status, app allowlist, in-memory recent-send display | Compose state plus `PairingStore` |
| [`NotificationRelayService`](../../android/app/src/main/java/com/piyush/phonebridge/relay/NotificationRelayService.kt) | Orchestrates posted/removed events, notification delivery, call sessions, dismissal, and cached client lifecycle | Android notification-listener service; `SupervisorJob + Dispatchers.IO` |
| [`NotificationFilter`](../../android/app/src/main/java/com/piyush/phonebridge/filter/NotificationFilter.kt) | Structural, category, allowlist, and empty-content gates | Stateless |
| [`DedupCache`](../../android/app/src/main/java/com/piyush/phonebridge/filter/DedupCache.kt) | Suppresses identical package/title/text content for 30 seconds | Process memory |
| [`CallSessionDecider`](../../android/app/src/main/java/com/piyush/phonebridge/relay/CallSessionDecider.kt) | Distinguishes new calls, caller-name updates, phone-side answers, and ignored reposts | Pure decision logic |
| [`CallControl`](../../android/app/src/main/java/com/piyush/phonebridge/relay/CallControl.kt) | Guards and executes answer, reject, silence, end, and ringer restoration | Process memory plus Android telephony state |
| [`MacClient`](../../android/app/src/main/java/com/piyush/phonebridge/net/MacClient.kt) | Pinned-TLS OkHttp client, bearer header, endpoint methods, 3-second ordinary timeouts and 55-second call-wait timeout | Cached by all credentials that affect a TLS session |
| [`HostResolver`](../../android/app/src/main/java/com/piyush/phonebridge/net/HostResolver.kt) | Bounded mDNS, verified fallback sweep, cache update, and sweep cooldown | Created by UI/service; one shared failure timestamp |
| [`PairingStore`](../../android/app/src/main/java/com/piyush/phonebridge/pairing/PairingStore.kt) | Pairing credentials, host cache, toggles, allowlist, and enrolled identity fingerprint | Encrypted preferences |
| [`ClientIdentity`](../../android/app/src/main/java/com/piyush/phonebridge/net/ClientIdentity.kt) | Creates, health-checks, rotates, and exposes the non-exportable mTLS identity | Android Keystore plus process caches |

## Local state model

| State | Persistence | Content |
|---|---|---|
| Pairing and preferences | Encrypted | Bearer token, Mac certificate fingerprint, verified numeric host, port, allowlist, global/call toggles, enrolled client fingerprint |
| Client identity | Keystore | EC P-256 private key and self-signed certificate; private key is non-exportable |
| Recent sends | Memory only | At most 20 outcome entries for the Activity tab |
| Duplicate cache | Memory only | Notification content fingerprints within a 30-second window |
| Delivered keys | Memory only | Up to roughly 200 successfully delivered keys used to decide whether removal needs `/dismiss` |
| Active calls | Memory only | One effective call session, caller name, and whether it was answered from the Mac |
| App icon cache | Memory only | 128×128 PNG bytes and SHA-256 hash by package |

`PairingStore.clear()` intentionally keeps the allowlist and user toggles while removing endpoint credentials and enrollment state.

On first secure-store access, an older plaintext token, pin, host/port, allowlist, and mirror toggles are copied into encrypted preferences. The plaintext store is cleared only after the encrypted commit succeeds. Android backup is disabled for the application, and enrollment is always tied to the fingerprint of the currently usable Keystore identity.

## Concurrency and lifecycle

- Notification callbacks launch work into one service-owned `SupervisorJob` on `Dispatchers.IO`; a failed event does not cancel other event work.
- The Compose UI uses a separate main-thread coroutine scope and moves probing/enrollment work to `Dispatchers.IO`.
- Active calls use a concurrent map; compound session decisions synchronize around that map. Delivered/answered sets are synchronized collections.
- `MacClient` is reused only while the bearer token, Mac fingerprint, and client-certificate fingerprint all match. Identity change closes pooled connections and cancels live calls.
- Listener disconnect and APK replacement both request an Android notification-listener rebind so system backoff does not leave mirroring dormant.
- There is no Android notification database or durable delivery queue.

## Permissions and platform services

| Capability | Requirement |
|---|---|
| Observe notifications | User grants notification-listener access to the non-exported service |
| Pair by QR | Camera permission; camera is declared optional at install time |
| Reach the Mac | Internet/network-state permissions and an active network |
| Answer/reject/end calls | `ANSWER_PHONE_CALLS`; end/reject require Android 9+ |
| Detect call state | `READ_PHONE_STATE` |
| Silence/restore ringer | User grants notification-policy (Do Not Disturb) access |

Call permissions are requested only when the user enables call mirroring. Pairing is refused if a usable Keystore client identity cannot be created.
