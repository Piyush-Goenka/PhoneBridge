# Self-Healing Discovery ("Pair Once, Find Forever"), Design

Date: 2026-07-16
Status: Approved (design agreed in session), extends 2026-07-14-android-mac-notification-bridge-design.md

## Goal

Scan the pairing QR exactly once, ever. After that, the phone must find the Mac
by itself across every network event: Mac IP change, router reboot, lid
close/reopen, Wi-Fi off/on, or both devices moving to a completely different
network. Re-pairing remains only for genuine trust events (cert/token reset,
app data cleared).

## Principle: trust and location are different things

The QR carries two kinds of data:

- **Trust** (permanent): `token`, `fp` (cert fingerprint). Network-independent,
  never expires.
- **Location** (volatile): `host`, `port`. Changes with the network.

Today a stale location forces redoing the trust ceremony. This design declares
location to be nothing but a cache, rebuilt automatically. The pinned
certificate fingerprint doubles as the Mac's permanent identity: a completed
TLS handshake against the pinned trust manager is cryptographic proof
"this host is my Mac", regardless of what IP it has.

## Phone: the resolution chain

All three send paths (notify, call, dismiss) share one resolver. Inside a
delivery attempt, in order:

1. **Cached host:port** from PairingStore. Almost always works, costs nothing.
2. **mDNS** (existing MacDiscovery, 4 s). Works on routers that allow multicast.
3. **Subnet sweep**: TCP-connect to `store.port` on every host of the phone's
   own subnet (parallel, ~300 ms connect timeout, ~64 concurrent), then a TLS
   handshake with the pinned trust manager on whichever hosts accepted. A
   fingerprint match identifies the Mac. Write the new IP into PairingStore.
4. Nothing found: drop, per the best-effort principle.

### Sweep guardrails (battery + etiquette)

- **Cooldown**: after a sweep that finds nothing, no new sweep for 90 s
  (the common failure is "Mac asleep", not "IP changed"; a chatty group chat
  must cost at most one sweep per window). mDNS stays uncooled, it is cheap.
- **Wi-Fi only, private IPv4 only** (10/8, 172.16/12, 192.168/16). Never on
  cellular.
- **Subnet cap**: sweep only /23 or smaller (≤ 510 hosts). Corporate /16
  networks are futile (client isolation) and rude to scan.
- **Ordering**: cached host first (routers often re-issue the same address),
  then ascending. Early exit on first verified hit.
- Runs only inside a notification/call/dismiss event. Nothing in the
  background, no listener sockets on the phone. Principles of the base spec
  hold.

## Mac: stay findable

- **Fixed port, always.** The sweep knocks on the pairing-time port, so the
  EADDRINUSE fallback to an ephemeral port is removed: retry 52735 briefly
  (stale instance shutting down), then fail loudly in the menu bar. A random
  port only "works" in the world where the QR is always rescanned.
- **On wake and network change** (NSWorkspace.didWakeNotification,
  NWPathMonitor): if the Mac's IPv4 changed, republish Bonjour and rebuild the
  QR window content. The QR then only matters for pairing new phones, but it
  must never show a stale IP.
- QR window content is regenerated on every open (today the first render is
  cached forever).
- **VPN-safe address pick (amended 2026-07-19).** The QR's host used to be
  "the source address that reaches 8.8.8.8", which under a VPN is the utun
  tunnel address, unreachable from the phone. `primaryIPv4` now enumerates
  interfaces, skips tunnels (utun/tun/tap/ppp/ipsec/awdl/llw/bridge), and
  prefers a private address on a real interface (en0 first); the routing
  trick remains only as a fallback. Mirroring itself never depended on the
  VPN: the server binds 0.0.0.0 and the phone talks straight to the LAN IP,
  whose connected route stays on en0 even when a VPN owns the default route.

## Considered and rejected

- **MAC-address addressing**: TCP needs an IP; Android blocks ARP table
  access since API 29; modern macOS randomizes per-network MACs. The stable
  identity is the certificate, not the hardware address. (A router-side DHCP
  reservation remains a fine zero-code complement.)
- **Mac-to-phone wake ping as a send gate**: requires a background listener on
  the phone (battery, Doze, multicast locks) over broadcast transports the
  router may block; a single lost ping would silently kill mirroring forever.
  Stateless lazy re-resolution cannot deadlock. A best-effort broadcast *hint*
  could be added later; never a gate.

## Failure modes

| Situation | Behaviour |
|---|---|
| Mac asleep | Cached fails, mDNS fails, one sweep fails, cooldown arms; drops cost one sweep per 90 s max |
| Mac IP changed on same network | First failed send triggers mDNS/sweep, cache heals, delivery proceeds |
| Both devices on a brand-new network | Sweep of the new subnet finds the Mac by fingerprint; no rescan |
| Phone on cellular / away | Guardrails skip the sweep entirely; drop |
| Subnet wider than /23 | Sweep skipped; mDNS is the only recovery; else drop |
| Port 52735 occupied on Mac | Server retries, then fails visibly; never hides on a random port |

## Testing

- JVM: SweepPlan (candidate enumeration, ordering, caps, private-range and
  cooldown logic) is pure and unit-tested. SweepProber verified against
  MockWebServer TLS with right and wrong pinned fingerprints.
- Swift: port-conflict now throws (replaces the ephemeral-fallback test).
- End-to-end on real hardware: corrupt the cached host on the phone, post a
  test notification, watch logcat as the sweep finds the Mac and the card
  appears.
