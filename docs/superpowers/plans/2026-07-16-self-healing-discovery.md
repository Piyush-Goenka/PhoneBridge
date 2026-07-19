# Self-Healing Discovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pair once, find forever: the phone recovers the Mac's address by itself (cached IP -> mDNS -> fingerprint-verified subnet sweep) on all send paths, and the Mac keeps itself findable (fixed port, fresh QR and Bonjour on wake/network change).

**Architecture:** Android gains a pure `SweepPlan` (IPv4 math + guardrails), a `SweepProber` (TCP knock + pinned TLS handshake = identity proof), and a `HostResolver` gluing cached-host -> mDNS -> sweep with a 90 s failure cooldown; `NotificationRelayService`'s three send paths all heal through it. The Mac's `BridgeServer` stops falling back to an ephemeral port, and `AppState` refreshes the QR window and Bonjour when the IP changes.

**Tech Stack:** Kotlin + coroutines + OkHttp/JSSE (Android), SwiftNIO + NIOSSL + Network.framework (Mac), JUnit4 + MockWebServer + okhttp-tls (Android tests), XCTest (Mac tests).

## Global Constraints

- NO `git commit` / `git push`: Piyush approves every commit personally. End tasks at "tests pass"; never run git write commands.
- Never use em dashes in any code comment, doc, or message.
- Wire protocol (`protocol.md`) is unchanged by this feature. Do not edit it.
- Spec: `docs/superpowers/specs/2026-07-16-self-healing-discovery-design.md`.
- Android module: `android/` (run gradle from that directory, `JAVA_HOME` per `local.properties`/environment). Mac package: `mac/` (run `swift test` from that directory).
- Sweep constants (from spec, do not tune silently): connect timeout 300 ms, handshake timeout 2000 ms, concurrency 64, cooldown 90 000 ms, min prefix /23, max prefix /30.
- Comment style: sparse, only for non-obvious constraints, matching the existing codebase.

---

### Task 1: Extract PinnedTls and refactor MacClient onto it

The sweep needs the same pinned trust manager MacClient builds inline today. Extract it so both share one implementation.

**Files:**
- Create: `android/app/src/main/java/com/piyush/phonebridge/net/PinnedTls.kt`
- Modify: `android/app/src/main/java/com/piyush/phonebridge/net/MacClient.kt:1-59` (imports + init block)
- Test: existing `android/app/src/test/java/com/piyush/phonebridge/net/MacClientTest.kt` (unchanged, must stay green)

**Interfaces:**
- Consumes: nothing new.
- Produces: `object PinnedTls { fun trustManager(fingerprintHex: String): X509TrustManager; fun socketFactory(trustManager: X509TrustManager): SSLSocketFactory }`. Task 3 uses both.

- [ ] **Step 1: Create PinnedTls.kt**

```kotlin
package com.piyush.phonebridge.net

import java.security.MessageDigest
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocketFactory
import javax.net.ssl.X509TrustManager

// TLS primitives pinned to the Mac's certificate. Trust is exactly one
// check: SHA-256 of the leaf DER equals the fingerprint from the QR.
object PinnedTls {

    fun trustManager(fingerprintHex: String): X509TrustManager {
        val pin = fingerprintHex.lowercase()
        return object : X509TrustManager {
            override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String) {
                throw CertificateException("client certificates not supported")
            }

            override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String) {
                val leaf = chain.firstOrNull()
                    ?: throw CertificateException("empty certificate chain")
                val fp = MessageDigest.getInstance("SHA-256").digest(leaf.encoded)
                    .joinToString("") { "%02x".format(it) }
                if (fp != pin) {
                    throw CertificateException("certificate fingerprint mismatch, re-pair needed")
                }
            }

            override fun getAcceptedIssuers(): Array<X509Certificate> = arrayOf()
        }
    }

    fun socketFactory(trustManager: X509TrustManager): SSLSocketFactory =
        SSLContext.getInstance("TLS").apply {
            init(null, arrayOf(trustManager), null)
        }.socketFactory
}
```

- [ ] **Step 2: Refactor MacClient.init to use it**

Replace the whole `init` block (the inline trust manager and SSLContext) with:

```kotlin
    init {
        val trustManager = PinnedTls.trustManager(fingerprintHex)
        client = OkHttpClient.Builder()
            .sslSocketFactory(PinnedTls.socketFactory(trustManager), trustManager)
            .hostnameVerifier { _, _ -> true }
            .connectTimeout(3, TimeUnit.SECONDS)
            .readTimeout(3, TimeUnit.SECONDS)
            .writeTimeout(3, TimeUnit.SECONDS)
            .build()
    }
```

Remove now-unused imports from MacClient (`java.security.MessageDigest`, `java.security.cert.X509Certificate`, `javax.net.ssl.SSLContext`, `javax.net.ssl.X509TrustManager`). Keep `java.security.cert.CertificateException` (still used in `post()`'s cause-walking).

- [ ] **Step 3: Run the existing client tests**

Run: `cd android && ./gradlew :app:testDebugUnitTest --tests 'com.piyush.phonebridge.net.MacClientTest'`
Expected: BUILD SUCCESSFUL, all MacClientTest cases pass (pinning behavior identical).

---

### Task 2: SweepPlan, the pure IPv4 planning logic

**Files:**
- Create: `android/app/src/main/java/com/piyush/phonebridge/net/SweepPlan.kt`
- Test: `android/app/src/test/java/com/piyush/phonebridge/net/SweepPlanTest.kt`

**Interfaces:**
- Consumes: nothing.
- Produces (Task 4 uses all): `object SweepPlan { const val COOLDOWN_MS: Long; fun shouldSweep(now: Long, lastFailureAt: Long): Boolean; fun isPrivateIpv4(ip: String): Boolean; fun candidates(ownIp: String, prefixLength: Int, cachedHost: String?): List<String> }`

- [ ] **Step 1: Write the failing tests**

```kotlin
package com.piyush.phonebridge.net

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SweepPlanTest {

    @Test
    fun fullSlash24EnumeratesNeighboursOnly() {
        val hosts = SweepPlan.candidates("192.168.1.37", 24, cachedHost = null)
        assertEquals(253, hosts.size)
        assertTrue("192.168.1.1" in hosts)
        assertTrue("192.168.1.254" in hosts)
        assertFalse("192.168.1.37" in hosts)   // own address
        assertFalse("192.168.1.0" in hosts)    // network address
        assertFalse("192.168.1.255" in hosts)  // broadcast address
    }

    @Test
    fun cachedHostProbedFirst() {
        val hosts = SweepPlan.candidates("192.168.1.37", 24, cachedHost = "192.168.1.50")
        assertEquals("192.168.1.50", hosts.first())
        assertEquals(253, hosts.size)
        assertEquals(1, hosts.count { it == "192.168.1.50" })
    }

    @Test
    fun cachedHostOutsideSubnetIgnored() {
        val hosts = SweepPlan.candidates("192.168.1.37", 24, cachedHost = "10.0.0.5")
        assertEquals("192.168.1.1", hosts.first())
    }

    @Test
    fun subnetsWiderThanSlash23AreRefused() {
        assertTrue(SweepPlan.candidates("10.1.2.3", 16, null).isEmpty())
        assertTrue(SweepPlan.candidates("10.1.2.3", 22, null).isEmpty())
        assertEquals(509, SweepPlan.candidates("10.1.2.3", 23, null).size)
    }

    @Test
    fun tinySubnetWorks() {
        assertEquals(listOf("192.168.1.1"), SweepPlan.candidates("192.168.1.2", 30, null))
    }

    @Test
    fun garbageInputYieldsNothing() {
        assertTrue(SweepPlan.candidates("not-an-ip", 24, null).isEmpty())
        assertTrue(SweepPlan.candidates("192.168.1.300", 24, null).isEmpty())
        assertTrue(SweepPlan.candidates("192.168.1.1", 31, null).isEmpty())
    }

    @Test
    fun privateRangesRecognised() {
        assertTrue(SweepPlan.isPrivateIpv4("10.0.0.1"))
        assertTrue(SweepPlan.isPrivateIpv4("172.16.0.1"))
        assertTrue(SweepPlan.isPrivateIpv4("172.31.255.254"))
        assertTrue(SweepPlan.isPrivateIpv4("192.168.29.107"))
        assertFalse(SweepPlan.isPrivateIpv4("172.32.0.1"))
        assertFalse(SweepPlan.isPrivateIpv4("8.8.8.8"))
        assertFalse(SweepPlan.isPrivateIpv4("garbage"))
    }

    @Test
    fun cooldownGatesRepeatSweeps() {
        assertTrue(SweepPlan.shouldSweep(now = 1_000_000, lastFailureAt = 0))
        assertFalse(SweepPlan.shouldSweep(now = 1_000_000, lastFailureAt = 999_000))
        assertTrue(SweepPlan.shouldSweep(now = 1_000_000, lastFailureAt = 910_000 - 1))
    }
}
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `cd android && ./gradlew :app:testDebugUnitTest --tests 'com.piyush.phonebridge.net.SweepPlanTest'`
Expected: compilation FAILURE (SweepPlan unresolved).

- [ ] **Step 3: Implement SweepPlan.kt**

```kotlin
package com.piyush.phonebridge.net

// Pure IPv4 math for the subnet sweep: which addresses to probe, in what
// order, and whether sweeping is allowed at all. No Android imports so it
// runs under plain JVM tests.
object SweepPlan {

    const val COOLDOWN_MS = 90_000L

    // /23 (510 hosts) is the widest subnet worth sweeping; anything wider
    // is a corporate network where a sweep is rude and futile.
    private const val MIN_PREFIX = 23
    private const val MAX_PREFIX = 30

    fun shouldSweep(now: Long, lastFailureAt: Long): Boolean =
        now - lastFailureAt >= COOLDOWN_MS

    fun isPrivateIpv4(ip: String): Boolean {
        val value = parse(ip) ?: return false
        val a = value ushr 24 and 0xff
        val b = value ushr 16 and 0xff
        return a == 10 || (a == 172 && b in 16..31) || (a == 192 && b == 168)
    }

    // Every host address in ownIp's subnet except self, network, and
    // broadcast; cached host first because routers often re-issue the same
    // address. Empty when the subnet is too wide or the input is not IPv4.
    fun candidates(ownIp: String, prefixLength: Int, cachedHost: String?): List<String> {
        if (prefixLength !in MIN_PREFIX..MAX_PREFIX) return emptyList()
        val own = parse(ownIp) ?: return emptyList()
        val mask = (-1 shl (32 - prefixLength))
        val network = own and mask
        val broadcast = network or mask.inv()
        val hosts = ((network + 1) until broadcast)
            .filter { it != own }
            .map { format(it) }
        val cached = cachedHost?.takeIf { it in hosts } ?: return hosts
        return listOf(cached) + hosts.filter { it != cached }
    }

    private fun parse(ip: String): Int? {
        val parts = ip.split(".")
        if (parts.size != 4) return null
        var value = 0
        for (part in parts) {
            val octet = part.toIntOrNull() ?: return null
            if (octet !in 0..255) return null
            value = (value shl 8) or octet
        }
        return value
    }

    private fun format(ip: Int): String =
        "${ip ushr 24 and 0xff}.${ip ushr 16 and 0xff}.${ip ushr 8 and 0xff}.${ip and 0xff}"
}
```

- [ ] **Step 4: Run tests, verify they pass**

Run: `cd android && ./gradlew :app:testDebugUnitTest --tests 'com.piyush.phonebridge.net.SweepPlanTest'`
Expected: BUILD SUCCESSFUL, 8 tests pass.

---

### Task 3: SweepProber, the TCP knock + pinned handshake funnel

**Files:**
- Create: `android/app/src/main/java/com/piyush/phonebridge/net/SweepProber.kt`
- Test: `android/app/src/test/java/com/piyush/phonebridge/net/SweepProberTest.kt`

**Interfaces:**
- Consumes: `PinnedTls.trustManager`, `PinnedTls.socketFactory` (Task 1).
- Produces (Task 4 uses): `class SweepProber(fingerprintHex: String, connectTimeoutMs: Int = 300, handshakeTimeoutMs: Int = 2_000, concurrency: Int = 64) { suspend fun findMac(candidates: List<String>, port: Int): String? }`

- [ ] **Step 1: Write the failing tests**

Uses the MockWebServer-over-TLS pattern from MacClientTest. `203.0.113.1` is TEST-NET-3, guaranteed unroutable, so it exercises the connect timeout.

```kotlin
package com.piyush.phonebridge.net

import kotlinx.coroutines.runBlocking
import okhttp3.mockwebserver.MockWebServer
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import java.security.MessageDigest

class SweepProberTest {

    private lateinit var server: MockWebServer
    private lateinit var fingerprint: String

    @Before
    fun setUp() {
        val cert = HeldCertificate.Builder()
            .addSubjectAlternativeName("localhost")
            .build()
        fingerprint = MessageDigest.getInstance("SHA-256")
            .digest(cert.certificate.encoded)
            .joinToString("") { "%02x".format(it) }
        val certs = HandshakeCertificates.Builder()
            .heldCertificate(cert)
            .build()
        server = MockWebServer()
        server.useHttps(certs.sslSocketFactory(), false)
        server.start()
    }

    @After
    fun tearDown() {
        server.shutdown()
    }

    @Test
    fun findsHostWithPinnedCertificate() = runBlocking {
        val prober = SweepProber(fingerprint)
        assertEquals(
            server.hostName,
            prober.findMac(listOf(server.hostName), server.port))
    }

    @Test
    fun rejectsHostWithWrongCertificate() = runBlocking {
        val prober = SweepProber("ab".repeat(32))
        assertNull(prober.findMac(listOf(server.hostName), server.port))
    }

    @Test
    fun skipsDeadHostsAndFindsTheMac() = runBlocking {
        val prober = SweepProber(fingerprint)
        assertEquals(
            server.hostName,
            prober.findMac(listOf("203.0.113.1", server.hostName), server.port))
    }

    @Test
    fun nothingListeningMeansNull() = runBlocking {
        val port = server.port
        server.shutdown()
        val prober = SweepProber(fingerprint)
        assertNull(prober.findMac(listOf("127.0.0.1"), port))
    }
}
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `cd android && ./gradlew :app:testDebugUnitTest --tests 'com.piyush.phonebridge.net.SweepProberTest'`
Expected: compilation FAILURE (SweepProber unresolved).

- [ ] **Step 3: Implement SweepProber.kt**

```kotlin
package com.piyush.phonebridge.net

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import java.net.InetSocketAddress
import java.net.Socket
import javax.net.ssl.SSLSocket

// Finds the Mac on the local subnet by knocking on its port and verifying
// the pinned certificate: a completed handshake against the pinned trust
// manager is cryptographic proof the host is the paired Mac. Cheap TCP
// connects weed out dead addresses before any TLS work happens.
class SweepProber(
    fingerprintHex: String,
    private val connectTimeoutMs: Int = 300,
    private val handshakeTimeoutMs: Int = 2_000,
    private val concurrency: Int = 64,
) {
    private val socketFactory =
        PinnedTls.socketFactory(PinnedTls.trustManager(fingerprintHex))

    suspend fun findMac(candidates: List<String>, port: Int): String? {
        for (chunk in candidates.chunked(concurrency)) {
            val verified = coroutineScope {
                chunk.map { ip ->
                    async(Dispatchers.IO) { if (probe(ip, port)) ip else null }
                }.awaitAll()
            }
            verified.firstOrNull { it != null }?.let { return it }
        }
        return null
    }

    private fun probe(ip: String, port: Int): Boolean = try {
        Socket().use { tcp ->
            tcp.connect(InetSocketAddress(ip, port), connectTimeoutMs)
            (socketFactory.createSocket(tcp, ip, port, true) as SSLSocket).use { tls ->
                tls.soTimeout = handshakeTimeoutMs
                tls.startHandshake()
                true
            }
        }
    } catch (e: Exception) {
        false
    }
}
```

- [ ] **Step 4: Run tests, verify they pass**

Run: `cd android && ./gradlew :app:testDebugUnitTest --tests 'com.piyush.phonebridge.net.SweepProberTest'`
Expected: BUILD SUCCESSFUL, 4 tests pass (the dead-host test takes ~300 ms extra, that is the timeout working).

---

### Task 4: HostResolver + wire all three send paths through it

**Files:**
- Create: `android/app/src/main/java/com/piyush/phonebridge/net/HostResolver.kt`
- Modify: `android/app/src/main/AndroidManifest.xml` (add ACCESS_NETWORK_STATE)
- Modify: `android/app/src/main/java/com/piyush/phonebridge/relay/NotificationRelayService.kt` (deliver, onNotificationRemoved, handleCall)
- Test: full unit suite + `assembleDebug` (HostResolver's Android glue has no JVM test; its logic lives in SweepPlan/SweepProber which do)

**Interfaces:**
- Consumes: `SweepPlan` (Task 2), `SweepProber` (Task 3), existing `MacDiscovery`, `PairingStore`.
- Produces: `class HostResolver(context: Context) { suspend fun rediscover(store: PairingStore, now: Long = System.currentTimeMillis()): Pair<String, Int>? }`

- [ ] **Step 1: Add the permission to AndroidManifest.xml**

After the INTERNET permission line add:

```xml
    <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
```

- [ ] **Step 2: Create HostResolver.kt**

```kotlin
package com.piyush.phonebridge.net

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.util.Log
import com.piyush.phonebridge.pairing.PairingStore
import java.net.Inet4Address

// The self-healing location layer. Trust (token + fingerprint) comes from
// the one-time QR scan and never expires; the Mac's address is only a
// cache, rebuilt here when it goes stale: mDNS first (one multicast
// query), then a fingerprint-verified subnet sweep for routers that block
// mDNS. Runs only inside a delivery attempt, never in the background.
class HostResolver(private val context: Context) {

    companion object {
        // Shared across calls: a sleeping Mac must cost at most one sweep
        // per cooldown window, not one per notification.
        @Volatile
        internal var lastSweepFailureAt = 0L
    }

    suspend fun rediscover(
        store: PairingStore,
        now: Long = System.currentTimeMillis(),
    ): Pair<String, Int>? {
        MacDiscovery(context).discover()?.let { (host, port) ->
            Log.d("PhoneBridge", "rediscover: mDNS found $host:$port")
            store.host = host
            store.port = port
            lastSweepFailureAt = 0L
            return host to port
        }

        val fingerprint = store.fingerprint ?: return null
        if (!SweepPlan.shouldSweep(now, lastSweepFailureAt)) {
            Log.d("PhoneBridge", "rediscover: sweep on cooldown")
            return null
        }
        val (ownIp, prefix) = wifiIpv4() ?: run {
            Log.d("PhoneBridge", "rediscover: not on Wi-Fi, no sweep")
            return null
        }
        if (!SweepPlan.isPrivateIpv4(ownIp)) return null
        val candidates = SweepPlan.candidates(ownIp, prefix, store.host)
        if (candidates.isEmpty()) return null

        Log.d("PhoneBridge", "rediscover: sweeping ${candidates.size} hosts on port ${store.port}")
        val found = SweepProber(fingerprint).findMac(candidates, store.port)
        return if (found != null) {
            Log.d("PhoneBridge", "rediscover: sweep found Mac at $found")
            store.host = found
            lastSweepFailureAt = 0L
            found to store.port
        } else {
            Log.d("PhoneBridge", "rediscover: sweep found nothing, cooldown armed")
            lastSweepFailureAt = now
            null
        }
    }

    // The phone's IPv4 and prefix length on the active Wi-Fi network,
    // or null when the active network is not Wi-Fi.
    private fun wifiIpv4(): Pair<String, Int>? {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val network = cm.activeNetwork ?: return null
        val caps = cm.getNetworkCapabilities(network) ?: return null
        if (!caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) return null
        val link = cm.getLinkProperties(network) ?: return null
        val ipv4 = link.linkAddresses.firstOrNull { it.address is Inet4Address }
            ?: return null
        val host = ipv4.address.hostAddress ?: return null
        return host to ipv4.prefixLength
    }
}
```

- [ ] **Step 3: Wire NotificationRelayService through the resolver**

Add field (next to `private var client: MacClient?`):

```kotlin
    private val resolver by lazy { HostResolver(this) }
```

Add import: `import com.piyush.phonebridge.net.HostResolver`. Remove the now-unused `import com.piyush.phonebridge.net.MacDiscovery`.

In `deliver()`, replace the rediscovery block:

```kotlin
        if (result is MacClient.SendResult.Failed) {
            val rediscovered = resolver.rediscover(store)
            if (rediscovered == null) {
                SendLog.add(n.appName, n.title, "dropped: Mac not found")
                return
            }
            host = rediscovered.first
            port = rediscovered.second
            result = macClient.postNotify(host, port, body)
        }
```

(Only the `MacDiscovery(this@NotificationRelayService).discover()` call changes to `resolver.rediscover(store)`; the store writes move inside the resolver, so delete the `store.host = host` / `store.port = port` lines here.)

In `onNotificationRemoved()`, replace the body of the `scope.launch` block so dismissals heal too:

```kotlin
        scope.launch {
            val store = PairingStore(this@NotificationRelayService)
            if (!store.isPaired) return@launch

            val macClient = clientFor(store) ?: return@launch
            val body = JSONObject().put("key", sbn.key).toString()
            val host = store.host
            val result = if (host != null) {
                macClient.postDismiss(host, store.port, body)
            } else {
                MacClient.SendResult.Failed("no cached host")
            }
            if (result is MacClient.SendResult.Failed) {
                resolver.rediscover(store)?.let { (newHost, newPort) ->
                    macClient.postDismiss(newHost, newPort, body)
                }
            }
        }
```

In `handleCall()`, replace everything from `val macClient = clientFor(store)` down to the `deliveredKeys.add(n.key)` line with:

```kotlin
        val macClient = clientFor(store)
        if (macClient == null) {
            SendLog.add("Call", caller, "call dropped: not paired")
            activeCallKeys.remove(n.key)
            return
        }

        val callBody = JSONObject()
            .put("v", 1)
            .put("key", n.key)
            .put("caller", caller)
            .put("postedAt", n.postedAt)
            .toString()

        var host = store.host
        var port = store.port
        var posted = if (host != null) {
            macClient.postCall(host, port, callBody)
        } else {
            MacClient.SendResult.Failed("no cached host")
        }
        if (posted !is MacClient.SendResult.Ok) {
            val rediscovered = resolver.rediscover(store)
            if (rediscovered != null) {
                host = rediscovered.first
                port = rediscovered.second
                posted = macClient.postCall(host, port, callBody)
            }
        }
        if (posted !is MacClient.SendResult.Ok || host == null) {
            SendLog.add("Call", caller, "call dropped: Mac unreachable")
            activeCallKeys.remove(n.key)
            return
        }
        deliveredKeys.add(n.key)
```

Then in the wait block below, replace `store.port` with `port` (both `postCallWait(host, store.port, waitBody)` becomes `postCallWait(host, port, waitBody)`).

- [ ] **Step 4: Run the full Android suite and build the APK**

Run: `cd android && ./gradlew :app:testDebugUnitTest :app:assembleDebug`
Expected: BUILD SUCCESSFUL, all tests (filter, dedup, QR, MacClient, SweepPlan, SweepProber) pass, APK at `app/build/outputs/apk/debug/app-debug.apk`.

---

### Task 5: Mac fixed-port policy

**Files:**
- Modify: `mac/Sources/PhoneBridgeCore/BridgeServer.swift:34-43` (the bind fallback)
- Modify: `mac/Tests/PhoneBridgeCoreTests/ServerIntegrationTests.swift:80-96` (replace the ephemeral-fallback test)

**Interfaces:**
- Consumes: nothing new.
- Produces: `BridgeServer.start` now throws when the preferred port stays busy (signature unchanged). Task 7's e2e relies on the port being stable at 52735.

- [ ] **Step 1: Replace the fallback test with the failing fixed-port test**

In `ServerIntegrationTests.swift`, delete `testFallsBackToEphemeralPortWhenPreferredTaken` entirely and add:

```swift
    func testThrowsWhenPreferredPortTaken() throws {
        let info = try Pairing.ensure(directory: dir)
        let secondHandler = RequestHandler(
            token: info.token,
            icons: try DiskIconStore(directory: dir.appendingPathComponent("icons")),
            sink: MockSink(),
            calls: CallActionRegistry(),
            callSink: MockCallSink())
        let secondServer = BridgeServer()
        defer { secondServer.stop() }
        XCTAssertThrowsError(try secondServer.start(
            certPath: info.certPath, keyPath: info.keyPath,
            handler: secondHandler, preferredPort: server.port))
    }
```

- [ ] **Step 2: Run it, verify it fails**

Run: `cd mac && swift test --filter ServerIntegrationTests`
Expected: `testThrowsWhenPreferredPortTaken` FAILS (current code silently binds an ephemeral port instead of throwing).

- [ ] **Step 3: Implement the retry-then-throw bind**

In `BridgeServer.start`, replace the `do/catch` around `bootstrap.bind` with:

```swift
        // The port is part of the pairing contract: the phone's subnet
        // sweep knocks on exactly this port, so a silent fallback to a
        // random port would make the Mac unfindable. Retry briefly (the
        // usual squatter is a stale instance still shutting down), then
        // fail loudly.
        var attempt = 0
        while true {
            do {
                channel = try bootstrap.bind(host: "0.0.0.0", port: preferredPort).wait()
                break
            } catch {
                attempt += 1
                guard let ioError = error as? IOError,
                      ioError.errnoCode == EADDRINUSE,
                      attempt < 3 else { throw error }
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
```

- [ ] **Step 4: Run the Mac suite**

Run: `cd mac && swift test`
Expected: all tests pass, including `testThrowsWhenPreferredPortTaken` (takes ~0.4 s: two retry sleeps) and the unchanged TLS round-trip tests (they use `preferredPort: 0`, which never collides).

---

### Task 6: Mac QR freshness + Bonjour republish on wake/network change

**Files:**
- Modify: `mac/Sources/PhoneBridge/AppState.swift` (QR content extraction, observers)

**Interfaces:**
- Consumes: existing `Pairing.qrPayload`, `Pairing.primaryIPv4`, `QRRenderer.image`, `BonjourAdvertiser`.
- Produces: no new public API; behavior only. No unit test target exists for the UI executable; verification is manual in Task 7.

- [ ] **Step 1: Extract fresh-on-every-render QR content**

In `AppState`, add below `showQRWindow()`:

```swift
    private func qrContent(info: PairingInfo) -> AnyView {
        let payload = Pairing.qrPayload(info: info, port: server.port)
        let image = QRRenderer.image(from: payload, size: 300)
        return AnyView(
            VStack(spacing: 12) {
                Text("Scan with the PhoneBridge Android app")
                    .font(.headline)
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 300, height: 300)
                Text("Port \(server.port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(24))
    }
```

- [ ] **Step 2: Rebuild the QR on every open**

Replace `showQRWindow()` with:

```swift
    func showQRWindow() {
        guard let pairing else { return }
        // The payload embeds the Mac's current IP, so it is rebuilt on
        // every open; a cached first render could show a dead address.
        if let existing = qrWindow {
            existing.contentView = NSHostingView(rootView: qrContent(info: pairing))
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = "Pair your phone"
        window.contentView = NSHostingView(rootView: qrContent(info: pairing))
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        qrWindow = window
    }
```

- [ ] **Step 3: Observe wake and network-path changes**

Add `import Network` at the top of AppState.swift. Add properties:

```swift
    private var pathMonitor: NWPathMonitor?
    private var lastKnownIPv4: String?
```

At the end of `init()` (after the do/catch), add:

```swift
        lastKnownIPv4 = Pairing.primaryIPv4()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshAfterNetworkEvent() }
        }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in self?.refreshAfterNetworkEvent() }
        }
        monitor.start(queue: .main)
        pathMonitor = monitor
```

And add the handler method:

```swift
    // Lid reopen or network change can hand the Mac a new address. The
    // server socket survives (it binds 0.0.0.0); what goes stale is the
    // advertisement and the QR, so refresh exactly those.
    private func refreshAfterNetworkEvent() {
        let current = Pairing.primaryIPv4()
        guard current != lastKnownIPv4 else { return }
        lastKnownIPv4 = current
        bonjour.stop()
        bonjour.publish(port: server.port)
        if let qrWindow, qrWindow.isVisible, let pairing {
            qrWindow.contentView = NSHostingView(rootView: qrContent(info: pairing))
        }
        statusLine = "Listening on port \(server.port)"
    }
```

- [ ] **Step 4: Build and smoke-test**

Run: `cd mac && swift build`
Expected: builds clean (warnings about NetService deprecation are pre-existing and accepted).

---

### Task 7: Full verification, unit to on-device end-to-end

**Files:** none created; this task exercises everything.

**Interfaces:**
- Consumes: everything above; the connected phone at wireless adb (`adb devices` must list a device; ports change per enablement, re-pair adb if needed).

- [ ] **Step 1: Both unit suites green**

Run: `cd mac && swift test` and `cd android && ./gradlew :app:testDebugUnitTest`
Expected: all pass.

- [ ] **Step 2: Rebuild and relaunch the Mac app**

Run: `pkill -x PhoneBridge; cd mac && ./scripts/make-app.sh install && open /Applications/PhoneBridge.app`
Expected: menu bar icon appears; `curl -sk https://localhost:52735/ -o /dev/null -w '%{http_code}'` returns non-000 (server up on the fixed port).

- [ ] **Step 3: Protocol regression via fake-phone**

Run: `cd mac && ./scripts/fake-phone.sh`
Expected: needIcon true, icon 200, needIcon false, dismiss 200; two cards appear on screen, second disappears at dismiss.

- [ ] **Step 4: Install the new APK on the phone**

Run: `adb install -r android/app/build/outputs/apk/debug/app-debug.apk`
Expected: `Success`. (If adb is disconnected, re-run `adb connect <phone-ip>:<port>` per the phone's wireless-debugging screen.)

- [ ] **Step 5: The headline e2e, sweep recovery from a poisoned cache**

The app is a debug build, so `run-as` can edit its prefs. Poison the cached host with a dead IP, restart the app process, allowlist the shell package, then post a test notification and watch the sweep heal it:

```bash
# 1. Stop the app process so SharedPreferences' in-memory cache dies with it
adb shell am force-stop com.piyush.phonebridge

# 2. Poison the cached host and allowlist com.android.shell for the test
adb shell "run-as com.piyush.phonebridge sed -i 's|name=\"host\">[^<]*<|name=\"host\">192.168.29.250<|' shared_prefs/pairing.xml"
adb shell "run-as com.piyush.phonebridge cat shared_prefs/pairing.xml"   # verify host + note allowlist
# If com.android.shell is not in the allowlist string-set, add it:
#   <set name="allowlist"> ... <string>com.android.shell</string> ... </set>

# 3. Re-bind the notification listener (force-stop unbinds it)
adb shell cmd notification disallow_listener com.piyush.phonebridge/.relay.NotificationRelayService
adb shell cmd notification allow_listener com.piyush.phonebridge/.relay.NotificationRelayService

# 4. Watch the relay decide
adb logcat -c && adb logcat -s PhoneBridge:D &

# 5. Post a test notification as com.android.shell
adb shell cmd notification post -t 'Sweep test' sweeptag 'hello from the sweep e2e'
```

Expected logcat sequence: `posted pkg=com.android.shell`, `delivering:`, then `rediscover: sweeping N hosts on port 52735`, then `rediscover: sweep found Mac at 192.168.29.X`, and a card on the Mac. Then verify the healed cache: `adb shell "run-as com.piyush.phonebridge cat shared_prefs/pairing.xml"` shows the Mac's real IP as `host`.

- [ ] **Step 6: Cooldown behaves**

Quit the Mac app (`pkill -x PhoneBridge`), post two notifications 10 s apart, and check logcat: the first triggers a sweep that finds nothing (`sweep found nothing, cooldown armed`), the second is dropped with `rediscover: sweep on cooldown` and NO second sweep. Relaunch the Mac app afterwards.

- [ ] **Step 7: Restore the phone's real allowlist state**

If `com.android.shell` was added for the test, remove it via the app's Apps tab (or repeat the sed edit), and confirm a real notification (e.g. WhatsApp) still mirrors.
