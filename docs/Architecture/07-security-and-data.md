# Security and data architecture

PhoneBridge handles sensitive notification previews and call metadata. Its security model assumes the QR is exchanged with physical user intent, the devices communicate over a local/private network, and neither device's logged-in account is already compromised.

## Layered request defenses

```mermaid
flowchart LR
    PEER(["Network peer"])
    IP{"1. Source IP is loopback,<br/>private, link-local, or CGNAT?"}
    CAP{"2. Connection capacity:<br/>≤64 total and ≤8 per IP?"}
    IDLE["3. 90-second idle timeout"]
    TLS{"4. TLS 1.2+;<br/>Android pins Mac leaf"}
    MTLS{"5. Locked mode mTLS;<br/>Mac pins enrolled phone leaf"}
    BODY{"6. HTTP body ≤2 MiB<br/>and method is POST?"}
    TOKEN{"7. Constant-time<br/>bearer-token match?"}
    INPUT{"8. Endpoint schema,<br/>length, time, and content checks?"}
    SINK["9. Bounded UI and storage sinks"]
    REJECT(["Close silently or return<br/>bounded 4xx/5xx JSON"])

    PEER --> IP
    IP -- "No" --> REJECT
    IP -- "Yes" --> CAP
    CAP -- "No" --> REJECT
    CAP -- "Yes" --> IDLE --> TLS
    TLS -- "Fail" --> REJECT
    TLS -- "Pass" --> MTLS
    MTLS -- "Fail" --> REJECT
    MTLS -- "Pass / open pairing mode" --> BODY
    BODY -- "Fail" --> REJECT
    BODY -- "Pass" --> TOKEN
    TOKEN -- "Fail" --> REJECT
    TOKEN -- "Pass" --> INPUT
    INPUT -- "Fail" --> REJECT
    INPUT -- "Pass" --> SINK

    classDef network fill:#e8f8ee,stroke:#15803d,color:#14532d;
    classDef security fill:#fff3e0,stroke:#d97706,stroke-width:1.5px,color:#78350f;
    classDef mac fill:#f3e8ff,stroke:#7c3aed,color:#2e1065;
    classDef terminal fill:#f3f4f6,stroke:#4b5563,color:#111827;
    class PEER,IDLE network;
    class IP,CAP,TLS,MTLS,BODY,TOKEN,INPUT security;
    class SINK mac;
    class REJECT terminal;
```

These layers address different failures. The token remains required even after mTLS; a valid client certificate alone is not enough. Conversely, in locked mode a leaked token alone cannot reach HTTP without the phone's private key.

## Trust bootstrap and steady-state trust

```mermaid
flowchart TD
    PHYSICAL["User opens Mac pairing UI<br/>and scans QR"]
    QR["QR supplies server pin,<br/>bearer token, and location hint"]
    LOCAL{"QR host resolves only to<br/>an allowed local address?"}
    PROBE{"Pinned TLS probe proves<br/>Mac owns QR certificate?"}
    STORE["Android stores verified numeric<br/>address and credentials encrypted"]
    CLIENT_ID["Android creates/uses healthy<br/>non-exportable EC P-256 identity"]
    ENROLL["Bearer-authenticated /enroll<br/>sends only client certificate DER"]
    LOCK["Mac pins exact phone leaf and<br/>restarts listener locked"]
    STEADY["Every request:<br/>server pin + client pin + bearer"]
    STOP(["Reject pairing"])

    PHYSICAL --> QR --> CLIENT_ID --> LOCAL
    LOCAL -- "No" --> STOP
    LOCAL -- "Yes" --> PROBE
    PROBE -- "No" --> STOP
    PROBE -- "Yes" --> STORE
    STORE --> ENROLL --> LOCK --> STEADY

    classDef android fill:#e8f1ff,stroke:#2563eb,color:#172554;
    classDef mac fill:#f3e8ff,stroke:#7c3aed,color:#2e1065;
    classDef security fill:#fff3e0,stroke:#d97706,color:#78350f;
    classDef terminal fill:#f3f4f6,stroke:#4b5563,color:#111827;
    class STORE,CLIENT_ID android;
    class LOCK mac;
    class PHYSICAL,QR,LOCAL,PROBE,ENROLL,STEADY security;
    class STOP terminal;
```

### Certificate roles

- The Mac uses a self-signed RSA server certificate. Android compares the SHA-256 of the presented leaf DER to the QR pin; hostname and public-CA validation are not part of the trust decision.
- Android uses a self-signed EC P-256 client certificate. The Mac byte-compares the presented leaf DER to `phone-cert.pem`; the TLS `CertificateVerify` proof demonstrates possession of the corresponding private key.
- The phone private key remains in Android Keystore. Client-identity health checks verify P-256 parameters and the raw ECDSA operation required by the TLS provider; an incompatible legacy key is replaced and must enroll again.
- Open mode does not request a client certificate. It exists for first enrollment or an explicitly opened pairing window; bearer authentication still protects every endpoint.

## Data placement and lifetime

```mermaid
flowchart LR
    subgraph ANDROID["Android"]
        PREFS[("EncryptedSharedPreferences<br/>token, Mac pin, verified host/port,<br/>allowlist, toggles, enrollment pin")]
        KEYSTORE[("Android Keystore<br/>EC P-256 private key + certificate")]
        AMEM[("Process memory<br/>dedup, delivered keys, calls,<br/>icon cache, recent-send log")]
    end

    WIRE["TLS-encrypted LAN traffic<br/>bounded notification/call JSON<br/>and requested PNG icons"]

    subgraph MAC["~/Library/Application Support/PhoneBridge — 0700"]
        SERVER[("key.pem + token — 0600<br/>cert.pem — public certificate")]
        PHONE[("phone-cert.pem — 0600<br/>enrolled public client certificate")]
        HKEY[("history.key — 0600<br/>random 256-bit AES key")]
        HFILE[("history.json — 0600<br/>AES-GCM ciphertext, max 20 entries")]
        ICONS[("icons/&lt;hash&gt;.png<br/>content-addressed cache inside private dir")]
        MMEM[("Process memory<br/>cards, call waits/actions,<br/>mirroring gate")]
    end

    PREFS -->|"destination, server pin, bearer"| WIRE
    KEYSTORE -->|"TLS signatures; private key never exported"| WIRE
    AMEM -->|"eligible event content"| WIRE
    SERVER -->|"server identity and token validation"| WIRE
    PHONE -->|"locked-mode client trust"| WIRE
    WIRE -->|"accepted notification/call metadata"| HFILE
    WIRE -->|"validated requested PNGs"| ICONS
    HKEY --> HFILE
    WIRE --> MMEM

    classDef android fill:#e8f1ff,stroke:#2563eb,color:#172554;
    classDef network fill:#e8f8ee,stroke:#15803d,color:#14532d;
    classDef data fill:#f3f4f6,stroke:#4b5563,color:#111827;
    class PREFS,KEYSTORE,AMEM android;
    class WIRE network;
    class SERVER,PHONE,HKEY,HFILE,ICONS,MMEM data;
```

### Retained data

| Data | Retention and deletion |
|---|---|
| Android pairing credentials | Persist encrypted until Android unpair or replacement pairing |
| Android client private key | Keystore lifetime; deleted on Android unpair or replaced only when health checks prove incompatibility |
| Android notification content | No durable store; only bounded process-memory diagnostics/caches |
| Mac bearer token and server key | Persist across launches; token rotates on Mac unpair |
| Enrolled phone certificate | One public certificate; deleted/replaced by Mac pairing lifecycle |
| Mac notification history | Newest 20 entries; clearable from history UI; AES-GCM encrypted when persisted |
| Mac icons | Content-addressed disk cache; referenced by notification history/cards |

If the history key cannot be created or loaded, the Mac keeps history in memory only. It does not write plaintext. If an existing history blob cannot be decrypted or decoded, it is deleted at startup rather than left as stale or possibly legacy plaintext data.

## Validation and resource bounds

| Boundary | Implemented control |
|---|---|
| Network origin | Mac accepts IPv4 loopback, RFC 1918, IPv4 link-local, and CGNAT; the address predicate allows only `::1` if an IPv6 peer is presented |
| Concurrency | 64 accepted connections globally, 8 per source IP |
| Slow clients | Close after 90 seconds with no read or write |
| Request body | 2 MiB maximum before endpoint routing |
| Methods and routing | POST only; unknown paths return 404 |
| Token | Bearer token compared through fixed-size SHA-256 digests and a full XOR fold |
| Notification freshness | Between 24 hours in the past and 1 hour in the future |
| Text fields | Protocol-specific character caps; Android truncates before sending |
| Icon | Strict hash shape; decoded PNG ≤512 KiB; PNG magic and SHA-256 verified |
| History | 20 newest entries |
| Visible notifications | At most 5 ordinary cards, normally 6 seconds each |
| Call waits | One pending wait and at most one buffered non-`none` action per call key |

## Discovery security

Bonjour/mDNS is unauthenticated. PhoneBridge never treats an mDNS response as identity:

1. Resolve the advertised host and port.
2. Complete a TLS handshake using the stored Mac certificate pin and Android client identity.
3. Cache the address only after the pinned handshake succeeds.

The QR hostname is handled similarly during pairing: Android requires active Wi-Fi, resolves only private/link-local/unique-local/CGNAT destinations, probes the candidates by pin, and stores the numeric address that actually passed. This prevents public-host redirection and later DNS rebinding of the cached pairing destination.

## Revocation and failure posture

- **Mac unpair fails closed.** It stops Bonjour/listening and severs existing sessions before rotating the token and deleting the enrolled certificate. If a step fails, the listener remains stopped.
- **Mode reload severs existing sessions.** A connection accepted under an old open/locked policy cannot survive by remaining pooled or keeping a long poll alive.
- **Android identity rotation invalidates clients.** Cached OkHttp calls and pooled TLS sessions are cancelled/evicted when the identity changes.
- **Locked-mode handshake rejects unknown phones before HTTP.** The exact enrolled leaf and its private-key proof are required.
- **Open mode is an explicit recovery/consent state.** During that window, the bearer token rather than mTLS is the phone-authentication layer.
- **Missing/corrupt enrolled-phone certificate reopens enrollment.** This is a deliberate recovery tradeoff: an actor able to alter the private application-support directory is already inside the logged-in user's local filesystem boundary.
- **Normal delivery favors availability over replay.** A failure drops current notification content rather than accumulating a sensitive queue.

## Threat/control summary

| Threat | Primary controls | Residual boundary |
|---|---|---|
| LAN peer impersonates the Mac | Exact server-certificate pin; QR endpoint proof before save | User must scan the intended QR on a trusted Mac display |
| LAN peer sends fake events | Locked-mode mTLS plus bearer token | Pairing window temporarily uses token-only client authentication |
| mDNS poisoning | Pin-verified discovery before cache update | Poisoning can delay discovery but cannot authenticate a false endpoint |
| Stolen QR photograph/token | mTLS blocks steady-state use; Mac unpair rotates token | While pairing is open, possession of a still-current token matters |
| Public port exposure | Private-source gate before TLS | Design is still intended for LAN/private VPN, not WAN publication |
| Oversized/malformed input | Connection/body/field/time/icon bounds | Bodies up to 2 MiB are buffered before token validation |
| Notification data at rest | Encrypted Android prefs; AES-GCM Mac history; owner-only Mac files | Icons are not separately encrypted but live under the 0700 private directory |
| Stale authenticated session after revocation | Child-channel tracking and forced close on stop/reload | In-flight best-effort operations can fail and are not replayed |

## Security-relevant implementation map

- Android encrypted state and identity: [`PairingStore.kt`](../../android/app/src/main/java/com/piyush/phonebridge/pairing/PairingStore.kt), [`ClientIdentity.kt`](../../android/app/src/main/java/com/piyush/phonebridge/net/ClientIdentity.kt)
- Android pinning and local-address rules: [`PinnedTls.kt`](../../android/app/src/main/java/com/piyush/phonebridge/net/PinnedTls.kt), [`LocalAddressPolicy.kt`](../../android/app/src/main/java/com/piyush/phonebridge/net/LocalAddressPolicy.kt)
- Mac pre-TLS gates and mTLS: [`BridgeServer.swift`](../../mac/Sources/PhoneBridgeCore/BridgeServer.swift), [`PrivateAddress.swift`](../../mac/Sources/PhoneBridgeCore/PrivateAddress.swift)
- Mac auth and payload validation: [`RequestHandler.swift`](../../mac/Sources/PhoneBridgeCore/RequestHandler.swift)
- Mac private files, history, and encryption: [`PrivateFile.swift`](../../mac/Sources/PhoneBridgeCore/PrivateFile.swift), [`HistoryCipher.swift`](../../mac/Sources/PhoneBridgeCore/HistoryCipher.swift), [`NotificationHistory.swift`](../../mac/Sources/PhoneBridgeCore/NotificationHistory.swift)
- Full contract and intentional tradeoffs: [protocol.md](../../protocol.md)
